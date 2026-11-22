<?php

namespace Tests\Feature;

use App\Models\Account;
use App\Models\AuditEvent;
use App\Models\Device;
use App\Models\Session;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

class AccountTest extends TestCase
{
    public function test_deleting_the_account_removes_everything(): void
    {
        [$ipad, $token, $account] = $this->device();
        [$mac] = $this->device('macOS', $account);
        [$keep] = $this->device('macOS');
        Session::create(['account_id' => $account->id, 'client_device_id' => $ipad->id, 'host_device_id' => $mac->id, 'started_at' => now()]);
        AuditEvent::record($account->id, $ipad->id, 'sign_in', '127.0.0.1');
        $this->as($token)->deleteJson('/v1/account')->assertNoContent();
        $this->assertNull(Account::find($account->id));
        $this->assertSame([$keep->id], Device::pluck('id')->all());
        $this->assertSame(0, Session::count());
        $this->assertSame(0, AuditEvent::count());
        $this->assertSame(1, DB::table('personal_access_tokens')->count());
    }

    public function test_health(): void
    {
        $this->get('/up')->assertOk();
    }
}
