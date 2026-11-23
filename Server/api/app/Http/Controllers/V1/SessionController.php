<?php

namespace App\Http\Controllers\V1;

use App\Events\SignalDelivered;
use App\Http\Controllers\Controller;
use App\Models\Device;
use App\Models\Session;
use App\Services\IceServers;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Validation\Rule;
use RuntimeException;

class SessionController extends Controller
{
    /**
     * POST /v1/sessions: a session to one of the account's Macs. Returns the session id and
     * ICE servers, and rings the Mac (plan section 12, over the internet, steps 1 and 2).
     */
    public function store(Request $request, IceServers $ice): JsonResponse
    {
        $data = $request->validate(['target' => ['required', 'string', 'regex:'.Device::ID_PATTERN]]);
        $caller = $request->user();
        $target = Device::active()->where('account_id', $caller->account_id)->find($data['target']);
        if (! $target || ! $target->isHost() || $target->id === $caller->id) {
            return response()->json(['message' => 'No such Mac on this account.'], 404);
        }
        try {
            $servers = $ice->for($caller);
        } catch (RuntimeException $e) {
            Log::error('ice servers unavailable', ['error' => $e->getMessage()]);

            return response()->json(['message' => 'The relay service is unavailable.'], 503);
        }
        $session = Session::create([
            'account_id' => $caller->account_id,
            'client_device_id' => $caller->id,
            'host_device_id' => $target->id,
            'started_at' => now(),
        ]);
        // The ring comes from the backend, so it is unsigned: the Mac only treats it as a hint,
        // checks the caller against its pins, and answers with a signed accept.
        $ring = json_encode([
            'v' => 1, 'type' => 'ring', 'session' => $session->id, 'from' => $caller->id, 'to' => $target->id,
            'seq' => 0, 'ts' => time(), 'body' => (object) [],
        ], JSON_UNESCAPED_SLASHES);
        event(new SignalDelivered($target->id, $ring));

        return response()->json(['session' => $session->id, ...$servers], 201);
    }

    /** GET /v1/ice-servers: for the Mac's side of a session. */
    public function iceServers(Request $request, IceServers $ice): JsonResponse
    {
        try {
            return response()->json($ice->for($request->user()));
        } catch (RuntimeException $e) {
            Log::error('ice servers unavailable', ['error' => $e->getMessage()]);

            return response()->json(['message' => 'The relay service is unavailable.'], 503);
        }
    }

    /** POST /v1/sessions/{id}/events: connected and ended, with path type and a summary. */
    public function event(Request $request, string $id): JsonResponse
    {
        $data = $request->validate([
            'type' => ['required', Rule::in(['connected', 'ended'])],
            'path_type' => ['nullable', 'string', 'max:32'],
            'end_reason' => ['nullable', 'string', 'max:32'],
            'avg_bitrate' => ['nullable', 'integer', 'min:0'],
            'avg_rtt' => ['nullable', 'integer', 'min:0'],
        ]);
        $device = $request->user();
        $session = Session::where('account_id', $device->account_id)->findOrFail($id);
        if (! $session->involves($device->id)) {
            abort(404);
        }
        if ($data['type'] === 'connected') {
            $session->connected_at ??= now();
            $session->path_type = $data['path_type'] ?? $session->path_type;
        } else {
            $session->ended_at ??= now();
            $session->fill(array_filter([
                'end_reason' => $data['end_reason'] ?? null,
                'path_type' => $data['path_type'] ?? null,
                'avg_bitrate' => $data['avg_bitrate'] ?? null,
                'avg_rtt' => $data['avg_rtt'] ?? null,
            ], fn ($v) => $v !== null));
        }
        $session->save();

        return response()->json(status: 204);
    }
}
