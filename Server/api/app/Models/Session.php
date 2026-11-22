<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Model;

/**
 * A session's metadata: who, when, how long, path type and a quality summary. Nothing from
 * inside the session (plan section 13).
 */
class Session extends Model
{
    use HasUlids;

    public $timestamps = false;

    protected $fillable = [
        'account_id', 'client_device_id', 'host_device_id', 'started_at', 'connected_at', 'ended_at',
        'path_type', 'end_reason', 'avg_bitrate', 'avg_rtt',
    ];

    protected function casts(): array
    {
        return [
            'started_at' => 'datetime',
            'connected_at' => 'datetime',
            'ended_at' => 'datetime',
        ];
    }

    public function involves(string $deviceId): bool
    {
        return $this->client_device_id === $deviceId || $this->host_device_id === $deviceId;
    }

    public function peerOf(string $deviceId): ?string
    {
        return match ($deviceId) {
            $this->client_device_id => $this->host_device_id,
            $this->host_device_id => $this->client_device_id,
            default => null,
        };
    }
}
