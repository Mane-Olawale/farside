<?php

namespace Tests\Feature;

use App\Models\Account;
use App\Models\AuditEvent;
use App\Models\Device;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

class AuthTest extends TestCase
{
    private int $ip = 0;

    /** Each call from its own address, so the sign-in limit stays out of the way. */
    private function signIn(array $claims = [], ?array $device = null, ?\OpenSSLAsymmetricKey $key = null, ?string $ip = null)
    {
        return $this->withServerVariables(['REMOTE_ADDR' => $ip ?? '10.0.0.'.(++$this->ip)])->postJson('/v1/auth/apple', [
            'identity_token' => $this->appleToken($claims, $key),
            'device' => $device ?? $this->deviceFields(),
        ]);
    }

    public function test_a_valid_token_registers_the_device_and_returns_its_token(): void
    {
        $fields = $this->deviceFields();
        $response = $this->signIn(device: $fields)->assertCreated();
        $token = $response->json('token');
        $this->assertNotEmpty($token);
        $this->assertSame($fields['id'], $response->json('device.id'));
        $this->assertSame(hash('sha256', base64_decode($fields['public_key'])), $response->json('device.key_fingerprint'));
        $this->assertSame(1, Account::count());
        $this->assertSame('device_registered', AuditEvent::first()->type);
        $this->as($token)->getJson('/v1/devices')->assertOk()->assertJsonCount(1, 'devices');
    }

    public function test_signing_in_again_replaces_the_token(): void
    {
        $fields = $this->deviceFields();
        $first = $this->signIn(device: $fields)->json('token');
        $second = $this->signIn(device: $fields)->assertOk()->json('token');
        $this->assertNotSame($first, $second);
        $this->assertSame(1, Device::find($fields['id'])->tokens()->count());
        $this->app['auth']->forgetGuards();
        $this->as($first)->getJson('/v1/devices')->assertUnauthorized();
        $this->as($second)->getJson('/v1/devices')->assertOk();
    }

    public function test_tokens_apple_did_not_issue_for_us_are_refused(): void
    {
        $this->signIn(['aud' => 'com.someone.else'])->assertUnauthorized();
        $this->signIn(['iss' => 'https://evil.example'])->assertUnauthorized();
        $this->signIn(['exp' => time() - 3600])->assertUnauthorized();
        $this->signIn(['sub' => ''])->assertUnauthorized();
        $other = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_RSA, 'private_key_bits' => 2048]);
        $this->signIn(key: $other)->assertUnauthorized();
        $this->postJson('/v1/auth/apple', ['identity_token' => 'not-a-jwt', 'device' => $this->deviceFields()])->assertUnauthorized();
        $this->assertSame(0, Account::count());
    }

    public function test_an_unknown_key_id_reloads_apples_keys_once(): void
    {
        Http::fake(['appleid.apple.com/*' => Http::response(['keys' => []])]);
        $this->postJson('/v1/auth/apple', [
            'identity_token' => $this->appleToken(kid: 'rotated'),
            'device' => $this->deviceFields(),
        ])->assertUnauthorized();
        Http::assertSentCount(1);
    }

    public function test_bad_device_details_are_refused(): void
    {
        $this->signIn(device: $this->deviceFields(overrides: ['public_key' => base64_encode(str_repeat('x', 65))]))->assertStatus(422);
        $this->signIn(device: $this->deviceFields(overrides: ['id' => 'dev_short']))->assertStatus(422);
        $this->signIn(device: $this->deviceFields(overrides: ['platform' => 'Android']))->assertStatus(422);
    }

    public function test_a_device_id_cannot_move_account_or_change_key(): void
    {
        $fields = $this->deviceFields();
        $this->signIn(device: $fields)->assertCreated();
        $this->signIn(['sub' => 'someone-else'], device: $fields)->assertStatus(409);
        $this->signIn(device: [...$fields, 'public_key' => $this->publicKey()])->assertStatus(409);
    }

    public function test_a_revoked_device_cannot_sign_back_in(): void
    {
        $fields = $this->deviceFields();
        $this->signIn(device: $fields)->assertCreated();
        Device::find($fields['id'])->forceFill(['revoked_at' => now()])->save();
        $this->signIn(device: $fields)->assertForbidden();
    }

    public function test_sign_in_is_limited_to_five_a_minute(): void
    {
        for ($i = 0; $i < 5; $i++) {
            $this->signIn(['aud' => 'wrong'], ip: '10.9.9.9')->assertUnauthorized();
        }
        $this->signIn(ip: '10.9.9.9')->assertStatus(429);
        $this->signIn(ip: '10.9.9.10')->assertCreated();
    }
}
