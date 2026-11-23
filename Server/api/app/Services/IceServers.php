<?php

namespace App\Services;

use App\Models\Device;
use Illuminate\Support\Facades\Http;
use RuntimeException;

/**
 * STUN and TURN for one device (plan section 13, TURN credentials). Credentials are short-lived
 * and minted per request; nothing secret ships in the apps.
 */
class IceServers
{
    /**
     * @param  array{provider: string, ttl: int, stun: list<string>, cloudflare_key_id: ?string,
     *     cloudflare_api_token: ?string, coturn_urls: list<string>, coturn_secret: ?string}  $config
     */
    public function __construct(private readonly array $config) {}

    /** @return array{ice_servers: list<array>, ttl: int} */
    public function for(Device $device): array
    {
        $ttl = (int) $this->config['ttl'];
        $servers = match ($this->config['provider']) {
            'cloudflare' => $this->cloudflare($ttl),
            'coturn' => [$this->coturn($device, $ttl)],
            default => [],
        };
        if ($this->config['stun'] !== []) {
            array_unshift($servers, ['urls' => $this->config['stun']]);
        }

        return ['ice_servers' => $servers, 'ttl' => $ttl];
    }

    /** Cloudflare Realtime TURN: its API mints the credentials. */
    private function cloudflare(int $ttl): array
    {
        $keyId = $this->config['cloudflare_key_id'];
        $token = $this->config['cloudflare_api_token'];
        if (! $keyId || ! $token) {
            throw new RuntimeException('Cloudflare TURN is not configured');
        }
        $response = Http::timeout(5)->withToken($token)->post(
            "https://rtc.live.cloudflare.com/v1/turn/keys/{$keyId}/credentials/generate-ice-servers",
            ['ttl' => $ttl],
        );
        if (! $response->successful()) {
            throw new RuntimeException('Cloudflare TURN refused: '.$response->status());
        }
        $servers = $response->json('iceServers');
        // One object or a list, depending on the endpoint version.
        $servers = isset($servers['urls']) ? [$servers] : (array) $servers;

        return array_values(array_map(fn (array $s) => array_filter([
            'urls' => (array) $s['urls'],
            'username' => $s['username'] ?? null,
            'credential' => $s['credential'] ?? null,
        ]), $servers));
    }

    /** coturn in shared-secret mode: the username is an expiry and the device id. */
    private function coturn(Device $device, int $ttl): array
    {
        $secret = $this->config['coturn_secret'];
        if (! $secret || $this->config['coturn_urls'] === []) {
            throw new RuntimeException('coturn is not configured');
        }
        $username = (time() + $ttl).':'.$device->id;

        return [
            'urls' => $this->config['coturn_urls'],
            'username' => $username,
            'credential' => base64_encode(hash_hmac('sha1', $username, $secret, true)),
        ];
    }
}
