<?php

namespace App\Services;

use Firebase\JWT\JWK;
use Firebase\JWT\JWT;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Throwable;

/**
 * Checks a Sign in with Apple identity token (plan section 13, accounts): signed by one of
 * Apple's current keys, issued by Apple, for one of our apps, and not expired. Returns Apple's
 * stable user id for our team.
 */
class AppleIdentityVerifier
{
    public const ISSUER = 'https://appleid.apple.com';

    public const KEYS_URL = 'https://appleid.apple.com/auth/keys';

    private const CACHE_KEY = 'apple-jwks';

    /** @param  list<string>  $audiences  The apps' bundle identifiers. */
    public function __construct(private readonly array $audiences) {}

    public function subject(string $token): string
    {
        if ($this->audiences === []) {
            throw new InvalidAppleToken('no audiences configured');
        }
        try {
            $claims = $this->decode($token, refreshed: false);
        } catch (InvalidAppleToken $e) {
            throw $e;
        } catch (Throwable $e) {
            throw new InvalidAppleToken($e->getMessage(), previous: $e);
        }
        if (($claims->iss ?? null) !== self::ISSUER) {
            throw new InvalidAppleToken('wrong issuer');
        }
        $audiences = (array) ($claims->aud ?? []);
        if (array_intersect($audiences, $this->audiences) === []) {
            throw new InvalidAppleToken('wrong audience');
        }
        if (! is_string($claims->sub ?? null) || $claims->sub === '') {
            throw new InvalidAppleToken('no subject');
        }

        return $claims->sub;
    }

    private function decode(string $token, bool $refreshed): object
    {
        JWT::$leeway = 60;
        try {
            return JWT::decode($token, JWK::parseKeySet($this->keys($refreshed), 'RS256'));
        } catch (\UnexpectedValueException $e) {
            // Apple rotates keys: an unknown key id means the cached set may be stale.
            if (! $refreshed && str_contains($e->getMessage(), '"kid"')) {
                return $this->decode($token, refreshed: true);
            }
            throw $e;
        }
    }

    private function keys(bool $refresh): array
    {
        if ($refresh) {
            Cache::forget(self::CACHE_KEY);
        }

        return Cache::remember(self::CACHE_KEY, now()->addDay(), function () {
            $response = Http::timeout(5)->retry(2, 200)->get(self::KEYS_URL);
            $keys = $response->json();
            if (! $response->successful() || ! is_array($keys['keys'] ?? null)) {
                throw new InvalidAppleToken('could not load Apple keys');
            }

            return $keys;
        });
    }
}
