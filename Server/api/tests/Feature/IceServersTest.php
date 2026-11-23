<?php

namespace Tests\Feature;

use App\Services\IceServers;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

class IceServersTest extends TestCase
{
    private function useTurn(array $config): void
    {
        config(['services.turn' => array_merge(config('services.turn'), $config)]);
        $this->app->forgetInstance(IceServers::class);
    }

    public function test_coturn_credentials_are_an_hmac_of_expiry_and_device(): void
    {
        $this->useTurn(['provider' => 'coturn', 'coturn_urls' => ['turn:turn.example.com:3478', 'turns:turn.example.com:5349'], 'coturn_secret' => 'shh']);
        [$mac, $token] = $this->device('macOS');
        $servers = $this->as($token)->getJson('/v1/ice-servers')->assertOk()->json('ice_servers');
        $this->assertCount(2, $servers);
        $turn = $servers[1];
        [$expiry, $device] = explode(':', $turn['username']);
        $this->assertSame($mac->id, $device);
        $this->assertEqualsWithDelta(time() + 43200, (int) $expiry, 5);
        $this->assertSame(base64_encode(hash_hmac('sha1', $turn['username'], 'shh', true)), $turn['credential']);
    }

    public function test_cloudflare_mints_credentials_with_the_ttl(): void
    {
        Http::fake(['rtc.live.cloudflare.com/*' => Http::response(['iceServers' => [
            ['urls' => ['stun:stun.cloudflare.com:3478']],
            ['urls' => ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'], 'username' => 'u', 'credential' => 'c'],
        ]])]);
        $this->useTurn(['provider' => 'cloudflare', 'cloudflare_key_id' => 'key123', 'cloudflare_api_token' => 'tok', 'stun' => []]);
        [, $token] = $this->device('macOS');
        $servers = $this->as($token)->getJson('/v1/ice-servers')->assertOk()->json('ice_servers');
        $this->assertSame('u', $servers[1]['username']);
        Http::assertSent(fn ($request) => $request->url() === 'https://rtc.live.cloudflare.com/v1/turn/keys/key123/credentials/generate-ice-servers'
            && $request['ttl'] === 43200 && $request->hasHeader('Authorization', 'Bearer tok'));
    }

    public function test_a_relay_outage_is_a_clear_503(): void
    {
        Http::fake(['rtc.live.cloudflare.com/*' => Http::response([], 500)]);
        $this->useTurn(['provider' => 'cloudflare', 'cloudflare_key_id' => 'key123', 'cloudflare_api_token' => 'tok']);
        [, $token] = $this->device('macOS');
        $this->as($token)->getJson('/v1/ice-servers')->assertStatus(503);
    }
}
