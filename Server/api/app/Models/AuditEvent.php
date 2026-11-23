<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * Sign-ins, registrations and revocations (plan section 13).
 */
class AuditEvent extends Model
{
    public const UPDATED_AT = null;

    protected $fillable = ['account_id', 'device_id', 'type', 'ip'];

    public static function record(string $accountId, ?string $deviceId, string $type, ?string $ip): void
    {
        static::create(['account_id' => $accountId, 'device_id' => $deviceId, 'type' => $type, 'ip' => $ip]);
    }
}
