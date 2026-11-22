<?php

namespace App\Console\Commands;

use App\Models\Account;
use App\Models\Device;
use Illuminate\Console\Command;

/**
 * Local development only: an account with a Mac and an iPad and their tokens, without Sign in
 * with Apple, for BackendClient's live tests (make backend-live-test). Refuses to run in
 * production.
 */
class MintTestDevices extends Command
{
    protected $signature = 'farside:test-devices';

    protected $description = 'Create a throwaway account with a Mac and an iPad, and print their tokens as JSON';

    public function handle(): int
    {
        if (app()->environment('production')) {
            $this->error('Not in production.');

            return self::FAILURE;
        }
        $account = Account::create(['apple_subject' => 'live-test-'.bin2hex(random_bytes(6))]);
        $out = ['account' => $account->id];
        foreach (['mac' => 'macOS', 'ipad' => 'iPadOS'] as $role => $platform) {
            $key = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1']);
            $ec = openssl_pkey_get_details($key)['ec'];
            $public = base64_encode("\x04".str_pad($ec['x'], 32, "\0", STR_PAD_LEFT).str_pad($ec['y'], 32, "\0", STR_PAD_LEFT));
            $alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
            $id = 'dev_';
            for ($i = 0; $i < 26; $i++) {
                $id .= $alphabet[random_int(0, 31)];
            }
            $device = new Device(['id' => $id, 'name' => "Live test $role", 'platform' => $platform,
                'public_key' => $public, 'key_fingerprint' => Device::fingerprint($public)]);
            $device->account_id = $account->id;
            $device->save();
            $out[$role] = ['id' => $id, 'token' => $device->createToken('device')->plainTextToken];
        }
        $this->line(json_encode($out));

        return self::SUCCESS;
    }
}
