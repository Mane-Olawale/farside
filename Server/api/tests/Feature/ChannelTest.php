<?php

namespace Tests\Feature;

use Illuminate\Broadcasting\BroadcastManager;
use Tests\TestCase;

class ChannelTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        config([
            'broadcasting.default' => 'reverb',
            'broadcasting.connections.reverb.key' => 'key',
            'broadcasting.connections.reverb.secret' => 'secret',
            'broadcasting.connections.reverb.app_id' => '1',
        ]);
        // Channels were registered on the test's null broadcaster at boot; register them again
        // on the real one.
        $this->app->make(BroadcastManager::class)->forgetDrivers();
        require base_path('routes/channels.php');
    }

    private function authorize(string $token, string $channel)
    {
        return $this->as($token)->postJson('/broadcasting/auth', ['socket_id' => '1234.5678', 'channel_name' => $channel]);
    }

    public function test_a_device_hears_only_its_own_channel(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$mac] = $this->device('macOS', $account);
        $this->authorize($token, "private-device.{$ipad->id}")->assertOk()->assertJsonStructure(['auth']);
        $this->authorize($token, "private-device.{$mac->id}")->assertForbidden();
    }

    public function test_presence_is_per_account(): void
    {
        [$ipad, $token, $account] = $this->device();
        [, , $other] = $this->device('macOS');
        $response = $this->authorize($token, "presence-account.{$account->id}")->assertOk();
        $this->assertSame($ipad->id, json_decode($response->json('channel_data'), true)['user_info']['id']);
        $this->authorize($token, "presence-account.{$other->id}")->assertForbidden();
    }

    public function test_no_token_no_channels(): void
    {
        [$ipad] = $this->device();
        $this->postJson('/broadcasting/auth', ['socket_id' => '1234.5678', 'channel_name' => "private-device.{$ipad->id}"])->assertUnauthorized();
    }
}
