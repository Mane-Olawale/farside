<?php

namespace Tests\Feature;

use App\Events\SignalDelivered;
use App\Models\Session;
use Illuminate\Support\Facades\Event;
use Tests\TestCase;

class SignalTest extends TestCase
{
    private $ipad;

    private $mac;

    private string $token;

    private string $macToken;

    private string $session;

    protected function setUp(): void
    {
        parent::setUp();
        Event::fake([SignalDelivered::class]);
        [$this->ipad, $this->token, $account] = $this->device();
        [$this->mac, $this->macToken] = $this->device('macOS', $account);
        $this->session = $this->as($this->token)->postJson('/v1/sessions', ['target' => $this->mac->id])->json('session');
    }

    private function envelope(array $changes = []): array
    {
        return array_merge([
            'v' => 1, 'type' => 'offer', 'session' => $this->session, 'from' => $this->ipad->id, 'to' => $this->mac->id,
            'seq' => 1, 'ts' => time(), 'body' => ['sdp' => 'v=0'], 'sig' => 'c2lnbmF0dXJl',
        ], $changes);
    }

    private function send(array $envelope, ?string $token = null, ?string $raw = null)
    {
        // The raw body, so the test controls every byte the Mac would receive.
        $this->as($token ?? $this->token);

        return $this->call('POST', '/v1/signal', [], [], [],
            $this->transformHeadersToServerVars(['Content-Type' => 'application/json', 'Accept' => 'application/json']),
            $raw ?? json_encode($envelope));
    }

    public function test_the_envelope_is_passed_on_exactly_as_sent(): void
    {
        $raw = json_encode($this->envelope(['body' => ['sdp' => "v=0\r\na=x", 'zzz' => [1, 2]]]));
        $this->send([], raw: $raw)->assertStatus(202);
        Event::assertDispatched(SignalDelivered::class, fn ($e) => $e->to === $this->mac->id && $e->envelope === $raw);
    }

    public function test_the_mac_answers_the_same_way(): void
    {
        $this->send($this->envelope(['type' => 'answer', 'from' => $this->mac->id, 'to' => $this->ipad->id]), $this->macToken)->assertStatus(202);
    }

    public function test_a_device_can_only_speak_for_itself(): void
    {
        [$other] = $this->device('iPadOS', $this->ipad->account);
        $this->send($this->envelope(['from' => $other->id]))->assertForbidden();
    }

    public function test_the_receiver_must_share_the_account(): void
    {
        [$strangerMac] = $this->device('macOS');
        $this->send($this->envelope(['to' => $strangerMac->id]))->assertNotFound();
    }

    public function test_session_messages_need_a_session_between_these_two(): void
    {
        $this->send($this->envelope(['session' => '01JDF3Q8ZK4W7N2M5R6T8V9XYA']))->assertNotFound();
        [$otherMac] = $this->device('macOS', $this->ipad->account);
        $this->send($this->envelope(['to' => $otherMac->id]))->assertNotFound();
        Event::assertDispatchedTimes(SignalDelivered::class, 1);  // only the ring
    }

    public function test_an_ended_session_accepts_only_bye(): void
    {
        Session::find($this->session)->forceFill(['ended_at' => now()])->save();
        $this->send($this->envelope())->assertStatus(410);
        $this->send($this->envelope(['type' => 'bye', 'body' => ['reason' => 'user_ended']]))->assertStatus(202);
    }

    public function test_size_and_shape_are_checked(): void
    {
        $this->send($this->envelope(['body' => ['sdp' => str_repeat('a', 16 * 1024)]]))->assertStatus(413);
        $this->send([], raw: 'not json')->assertStatus(422);
        foreach ([['v' => 2], ['type' => 'ring'], ['sig' => ''], ['seq' => '1'], ['from' => 'x']] as $bad) {
            $this->send($this->envelope($bad))->assertStatus(422);
        }
        $envelope = $this->envelope();
        unset($envelope['sig']);
        $this->send($envelope)->assertStatus(422);
    }

    public function test_sixty_messages_a_minute_per_session(): void
    {
        for ($i = 1; $i <= 60; $i++) {
            $this->send($this->envelope(['type' => 'candidate', 'seq' => $i]))->assertStatus(202);
        }
        $this->send($this->envelope(['type' => 'candidate', 'seq' => 61]))->assertStatus(429);
    }

    public function test_pairing_goes_to_a_mac_without_a_session(): void
    {
        $this->send($this->envelope(['type' => 'pair', 'session' => 'pairing-1']))->assertStatus(202);
        $this->send($this->envelope(['type' => 'paired', 'session' => 'pairing-1', 'from' => $this->mac->id, 'to' => $this->ipad->id]), $this->macToken)->assertStatus(202);
        [$otherIpad] = $this->device('iPadOS', $this->ipad->account);
        $this->send($this->envelope(['type' => 'pair', 'session' => 'pairing-2', 'to' => $otherIpad->id]))->assertStatus(422);
    }
}
