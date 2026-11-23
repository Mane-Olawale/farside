<?php

namespace Tests\Feature;

use App\Events\SignalDelivered;
use App\Models\Session;
use Illuminate\Support\Facades\Event;
use Tests\TestCase;

class SessionTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        Event::fake([SignalDelivered::class]);
    }

    public function test_creating_a_session_rings_the_mac_and_returns_ice_servers(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$mac] = $this->device('macOS', $account);
        $response = $this->as($token)->postJson('/v1/sessions', ['target' => $mac->id])->assertCreated();
        $id = $response->json('session');
        $this->assertSame([['urls' => ['stun:stun.cloudflare.com:3478']]], $response->json('ice_servers'));
        $this->assertSame(43200, $response->json('ttl'));
        $session = Session::find($id);
        $this->assertSame($ipad->id, $session->client_device_id);
        $this->assertSame($mac->id, $session->host_device_id);
        Event::assertDispatched(SignalDelivered::class, function (SignalDelivered $e) use ($mac, $ipad, $id) {
            $ring = json_decode($e->envelope, true);

            return $e->to === $mac->id && $ring['type'] === 'ring' && $ring['session'] === $id && $ring['from'] === $ipad->id;
        });
    }

    public function test_only_this_accounts_macs_can_be_called(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$otherIpad] = $this->device('iPadOS', $account);
        [$strangerMac] = $this->device('macOS');
        $this->as($token)->postJson('/v1/sessions', ['target' => $otherIpad->id])->assertNotFound();
        $this->as($token)->postJson('/v1/sessions', ['target' => $strangerMac->id])->assertNotFound();
        $this->as($token)->postJson('/v1/sessions', ['target' => 'dev_nope'])->assertStatus(422);
        Event::assertNotDispatched(SignalDelivered::class);
    }

    public function test_session_creation_is_limited_to_ten_a_minute(): void
    {
        [, $token, $account] = $this->device();
        [$mac] = $this->device('macOS', $account);
        for ($i = 0; $i < 10; $i++) {
            $this->as($token)->postJson('/v1/sessions', ['target' => $mac->id])->assertCreated();
        }
        $this->as($token)->postJson('/v1/sessions', ['target' => $mac->id])->assertStatus(429);
    }

    public function test_events_record_metadata_from_participants_only(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$mac, $macToken] = $this->device('macOS', $account);
        [, $outsiderToken] = $this->device('iPadOS', $account);
        $id = $this->as($token)->postJson('/v1/sessions', ['target' => $mac->id])->json('session');
        $this->as($macToken)->postJson("/v1/sessions/$id/events", ['type' => 'connected', 'path_type' => 'host'])->assertNoContent();
        $this->as($token)->postJson("/v1/sessions/$id/events", [
            'type' => 'ended', 'end_reason' => 'user_ended', 'avg_bitrate' => 8000, 'avg_rtt' => 12,
        ])->assertNoContent();
        $this->app['auth']->forgetGuards();
        $this->as($outsiderToken)->postJson("/v1/sessions/$id/events", ['type' => 'ended'])->assertNotFound();
        $session = Session::find($id);
        $this->assertNotNull($session->connected_at);
        $this->assertNotNull($session->ended_at);
        $this->assertSame('host', $session->path_type);
        $this->assertSame('user_ended', $session->end_reason);
        $this->assertSame(8000, $session->avg_bitrate);
    }

    public function test_the_mac_fetches_its_own_ice_servers(): void
    {
        [, $macToken] = $this->device('macOS');
        $this->as($macToken)->getJson('/v1/ice-servers')->assertOk()->assertJsonPath('ttl', 43200);
    }
}
