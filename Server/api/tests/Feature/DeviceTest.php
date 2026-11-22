<?php

namespace Tests\Feature;

use App\Events\DeviceRevoked;
use Illuminate\Support\Facades\Event;
use Tests\TestCase;

class DeviceTest extends TestCase
{
    public function test_lists_only_this_accounts_active_devices(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$mac] = $this->device('macOS', $account);
        [$revoked] = $this->device('iPadOS', $account);
        $revoked->forceFill(['revoked_at' => now()])->save();
        $this->device('macOS');  // another account
        $ids = collect($this->as($token)->getJson('/v1/devices')->assertOk()->json('devices'))->pluck('id')->all();
        $this->assertEqualsCanonicalizing([$ipad->id, $mac->id], $ids);
    }

    public function test_rename(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$mac] = $this->device('macOS', $account);
        $this->as($token)->patchJson("/v1/devices/{$mac->id}", ['name' => 'Office Mac'])->assertOk()->assertJsonPath('device.name', 'Office Mac');
    }

    public function test_revoking_kills_the_token_and_tells_the_others(): void
    {
        Event::fake([DeviceRevoked::class]);
        [$mac, $macToken, $account] = $this->device('macOS');
        [$ipad, $ipadToken] = $this->device('iPadOS', $account);
        $this->as($macToken)->deleteJson("/v1/devices/{$ipad->id}")->assertNoContent();
        $this->assertNotNull($ipad->fresh()->revoked_at);
        $this->app['auth']->forgetGuards();
        $this->as($ipadToken)->getJson('/v1/devices')->assertUnauthorized();
        Event::assertDispatched(DeviceRevoked::class, fn ($e) => $e->deviceId === $ipad->id && $e->recipients === [$mac->id]);
        $this->assertDatabaseHas('audit_events', ['device_id' => $ipad->id, 'type' => 'device_revoked']);
    }

    public function test_a_revoked_device_is_refused_even_with_a_token(): void
    {
        [$ipad, $token] = $this->device();
        $ipad->forceFill(['revoked_at' => now()])->save();
        $this->as($token)->getJson('/v1/devices')->assertUnauthorized();
    }

    public function test_another_accounts_device_is_out_of_reach(): void
    {
        [, $token] = $this->device();
        [$stranger] = $this->device('macOS');
        $this->as($token)->patchJson("/v1/devices/{$stranger->id}", ['name' => 'Mine now'])->assertNotFound();
        $this->as($token)->deleteJson("/v1/devices/{$stranger->id}")->assertNotFound();
        $this->assertNull($stranger->fresh()->revoked_at);
    }

    public function test_refreshing_details_keeps_the_key(): void
    {
        [$ipad, $token] = $this->device();
        $fields = ['name' => 'Renamed', 'platform' => 'iPadOS', 'app_version' => '0.4', 'public_key' => $ipad->public_key];
        $this->as($token)->postJson('/v1/devices', $fields)->assertOk()->assertJsonPath('device.app_version', '0.4');
        $this->as($token)->postJson('/v1/devices', [...$fields, 'public_key' => $this->publicKey()])->assertStatus(409);
    }

    public function test_no_token_no_access(): void
    {
        $this->getJson('/v1/devices')->assertUnauthorized();
        $this->withHeader('Authorization', 'Bearer 1|nonsense')->getJson('/v1/devices')->assertUnauthorized();
    }

    public function test_last_seen_is_recorded(): void
    {
        [$ipad, $token] = $this->device();
        $this->assertNull($ipad->last_seen_at);
        $this->as($token)->getJson('/v1/devices')->assertOk();
        $this->assertNotNull($ipad->fresh()->last_seen_at);
    }
}
