<?php

namespace App\Http\Controllers\V1;

use App\Events\DeviceRevoked;
use App\Http\Controllers\Controller;
use App\Models\AuditEvent;
use App\Models\Device;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class DeviceController extends Controller
{
    /** GET /v1/devices: the account's devices. Online status comes from the presence channel. */
    public function index(Request $request): JsonResponse
    {
        $devices = Device::active()->where('account_id', $request->user()->account_id)->orderBy('created_at')->get();

        return response()->json(['devices' => $devices->map->summary()->values()]);
    }

    /** POST /v1/devices: refreshes this device's details. The key and id never change. */
    public function register(Request $request): JsonResponse
    {
        $data = $request->validate([
            'name' => ['required', 'string', 'max:100'],
            'platform' => ['required', Rule::in(Device::PLATFORMS)],
            'model' => ['nullable', 'string', 'max:64'],
            'os_version' => ['nullable', 'string', 'max:32'],
            'app_version' => ['nullable', 'string', 'max:32'],
            'public_key' => ['required', 'string', 'max:100'],
        ]);
        $device = $request->user();
        if ($data['public_key'] !== $device->public_key || $data['platform'] !== $device->platform) {
            return response()->json(['message' => 'A device keeps its key and platform. Sign in again as a new device.'], 409);
        }
        $device->fill($data)->save();

        return response()->json(['device' => $device->summary()]);
    }

    /** PATCH /v1/devices/{id}: rename. */
    public function update(Request $request, string $id): JsonResponse
    {
        $device = $this->find($request, $id);
        $device->update($request->validate(['name' => ['required', 'string', 'max:100']]));

        return response()->json(['device' => $device->summary()]);
    }

    /**
     * DELETE /v1/devices/{id}: revoke. Its token stops working at once, its sockets can no
     * longer be authorized, and the account's other devices are told so a Mac drops its pin.
     */
    public function destroy(Request $request, string $id): JsonResponse
    {
        $device = $this->find($request, $id);
        $device->tokens()->delete();
        $device->revoked_at = now();
        $device->save();
        AuditEvent::record($device->account_id, $device->id, 'device_revoked', $request->ip());
        $others = Device::active()->where('account_id', $device->account_id)->pluck('id')->all();
        if ($others !== []) {
            event(new DeviceRevoked($device->id, $others));
        }

        return response()->json(status: 204);
    }

    private function find(Request $request, string $id): Device
    {
        return Device::active()->where('account_id', $request->user()->account_id)->findOrFail($id);
    }
}
