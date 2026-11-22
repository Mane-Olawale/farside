<?php

namespace App\Events;

use Illuminate\Broadcasting\PrivateChannel;
use Illuminate\Contracts\Broadcasting\ShouldBroadcastNow;

/**
 * A device was revoked. Every other device on the account hears it, and a Mac drops its pin
 * (plan section 14: the backend may remove trust but never add it).
 */
class DeviceRevoked implements ShouldBroadcastNow
{
    /** @param  list<string>  $recipients */
    public function __construct(public readonly string $deviceId, public readonly array $recipients) {}

    public function broadcastOn(): array
    {
        return array_map(fn (string $id) => new PrivateChannel('device.'.$id), $this->recipients);
    }

    public function broadcastAs(): string
    {
        return 'revoked';
    }

    public function broadcastWith(): array
    {
        return ['device' => $this->deviceId];
    }
}
