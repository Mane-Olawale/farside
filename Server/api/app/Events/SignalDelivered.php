<?php

namespace App\Events;

use Illuminate\Broadcasting\PrivateChannel;
use Illuminate\Contracts\Broadcasting\ShouldBroadcastNow;

/**
 * One signaling envelope for one device, passed through as received (plan section 13,
 * signaling design: the backend reads the routing fields and never the body).
 */
class SignalDelivered implements ShouldBroadcastNow
{
    public function __construct(public readonly string $to, public readonly string $envelope) {}

    public function broadcastOn(): array
    {
        return [new PrivateChannel('device.'.$this->to)];
    }

    public function broadcastAs(): string
    {
        return 'signal';
    }

    public function broadcastWith(): array
    {
        return ['envelope' => $this->envelope];
    }
}
