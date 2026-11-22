<?php

namespace Tests;

use App\Models\Account;
use App\Models\Device;
use App\Services\AppleIdentityVerifier;
use Firebase\JWT\JWT;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Facades\Cache;

abstract class TestCase extends BaseTestCase
{
    use RefreshDatabase;

    public const AUDIENCE = 'com.example.farside.client';

    /** A stand-in for Apple's signing key, and its public half as Apple would publish it. */
    protected static ?\OpenSSLAsymmetricKey $appleKey = null;

    protected function setUp(): void
    {
        parent::setUp();
        static::$appleKey ??= openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_RSA, 'private_key_bits' => 2048]);
        config(['services.apple.audiences' => [self::AUDIENCE, 'com.example.farside.host']]);
        $this->app->forgetInstance(AppleIdentityVerifier::class);
        $details = openssl_pkey_get_details(static::$appleKey);
        Cache::put('apple-jwks', ['keys' => [[
            'kty' => 'RSA', 'kid' => 'test-key', 'use' => 'sig', 'alg' => 'RS256',
            'n' => self::b64url($details['rsa']['n']), 'e' => self::b64url($details['rsa']['e']),
        ]]], now()->addDay());
    }

    protected static function b64url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    /** An Apple identity token with the given claims changed. */
    protected function appleToken(array $claims = [], ?\OpenSSLAsymmetricKey $key = null, string $kid = 'test-key'): string
    {
        $claims = array_merge([
            'iss' => 'https://appleid.apple.com', 'aud' => self::AUDIENCE, 'sub' => '001234.abcd.5678',
            'iat' => time(), 'exp' => time() + 600,
        ], $claims);
        openssl_pkey_export($key ?? static::$appleKey, $pem);

        return JWT::encode($claims, $pem, 'RS256', $kid);
    }

    /** A fresh P-256 public key, base64 of the uncompressed point, as the apps send it. */
    protected function publicKey(): string
    {
        $key = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1']);
        $ec = openssl_pkey_get_details($key)['ec'];

        return base64_encode("\x04".str_pad($ec['x'], 32, "\0", STR_PAD_LEFT).str_pad($ec['y'], 32, "\0", STR_PAD_LEFT));
    }

    protected function deviceId(): string
    {
        $alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
        $id = 'dev_';
        for ($i = 0; $i < 26; $i++) {
            $id .= $alphabet[random_int(0, 31)];
        }

        return $id;
    }

    protected function deviceFields(string $platform = 'iPadOS', array $overrides = []): array
    {
        return array_merge([
            'id' => $this->deviceId(), 'name' => $platform === 'macOS' ? 'Studio Mac' : 'iPad Pro',
            'platform' => $platform, 'model' => 'Test', 'os_version' => '26.0', 'app_version' => '0.3',
            'public_key' => $this->publicKey(),
        ], $overrides);
    }

    /** A registered device and its token, on the given account (new if null). */
    protected function device(string $platform = 'iPadOS', ?Account $account = null): array
    {
        $account ??= Account::create(['apple_subject' => 'sub-'.uniqid()]);
        $fields = $this->deviceFields($platform);
        $device = new Device($fields + ['key_fingerprint' => Device::fingerprint($fields['public_key'])]);
        $device->account_id = $account->id;
        $device->save();

        return [$device, $device->createToken('device')->plainTextToken, $account];
    }

    /** Requests as the device with this token. Guards cache the last user, so forget it. */
    protected function as(string $token): static
    {
        $this->app['auth']->forgetGuards();

        return $this->withHeader('Authorization', 'Bearer '.$token);
    }
}
