<?php

use App\Models\Device;
use Illuminate\Support\Facades\Broadcast;

// Plan section 13, signaling design. Each device hears its own signaling on
// private-device.{id}, and only that device's token can subscribe.
Broadcast::channel('device.{id}', function (Device $device, string $id) {
    return $device->id === $id && $device->revoked_at === null;
});

// Presence per account: the iPad reads which Macs are online from the member list.
Broadcast::channel('account.{id}', function (Device $device, string $id) {
    if ($device->account_id !== $id || $device->revoked_at !== null) {
        return false;
    }

    return ['id' => $device->id, 'name' => $device->name, 'platform' => $device->platform];
});
