<?php

namespace App\Http\Controllers\V1;

use App\Events\SignalDelivered;
use App\Http\Controllers\Controller;
use App\Models\Device;
use App\Models\Session;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\RateLimiter;

/**
 * POST /v1/signal (plan section 13, signaling design): checks the token, that sender and
 * receiver share an account, the session and rate limits, and passes the envelope on as it
 * arrived. Signatures are the devices' business: the backend has no device keys to forge with.
 */
class SignalController extends Controller
{
    public const MAX_BYTES = 16 * 1024;

    /** Types that belong to a session the backend created. */
    private const SESSION_TYPES = ['accept', 'reject', 'offer', 'answer', 'candidate', 'restart', 'bye'];

    /** Pairing through the backend, when the iPad and the Mac are not on one network. */
    private const PAIRING_TYPES = ['pair', 'paired'];

    public function __invoke(Request $request): JsonResponse
    {
        $response = $this->route($request);
        if ($response->getStatusCode() >= 400) {
            // Routing facts only: never the body.
            $envelope = json_decode($request->getContent(), true);
            Log::warning('signal refused', [
                'status' => $response->getStatusCode(),
                'type' => is_array($envelope) ? ($envelope['type'] ?? null) : null,
                'session' => is_array($envelope) ? ($envelope['session'] ?? null) : null,
            ]);
        }

        return $response;
    }

    private function route(Request $request): JsonResponse
    {
        $raw = $request->getContent();
        if (strlen($raw) > self::MAX_BYTES) {
            return response()->json(['message' => 'Envelope too large.'], 413);
        }
        $envelope = json_decode($raw, true);
        if (! is_array($envelope) || ! $this->wellFormed($envelope)) {
            return response()->json(['message' => 'Malformed envelope.'], 422);
        }
        $sender = $request->user();
        if ($envelope['from'] !== $sender->id) {
            return response()->json(['message' => 'The envelope is not from this device.'], 403);
        }
        $target = Device::active()->where('account_id', $sender->account_id)->find($envelope['to']);
        if (! $target || $target->id === $sender->id) {
            return response()->json(['message' => 'No such device on this account.'], 404);
        }

        if (in_array($envelope['type'], self::SESSION_TYPES, true)) {
            $session = Session::where('account_id', $sender->account_id)->find($envelope['session']);
            if (! $session || $session->peerOf($sender->id) !== $target->id) {
                return response()->json(['message' => 'No such session.'], 404);
            }
            if ($session->ended_at && $envelope['type'] !== 'bye') {
                return response()->json(['message' => 'The session has ended.'], 410);
            }
        } elseif ($envelope['type'] === 'pair' && ! $target->isHost()) {
            return response()->json(['message' => 'Only a Mac can be paired with.'], 422);
        }

        $key = 'signal:'.$envelope['session'];
        if (RateLimiter::tooManyAttempts($key, 60)) {
            return response()->json(['message' => 'Too many signaling messages.'], 429);
        }
        RateLimiter::hit($key, 60);

        event(new SignalDelivered($target->id, $raw));

        return response()->json(status: 202);
    }

    private function wellFormed(array $e): bool
    {
        return ($e['v'] ?? null) === 1
            && in_array($e['type'] ?? null, [...self::SESSION_TYPES, ...self::PAIRING_TYPES], true)
            && is_string($e['session'] ?? null) && strlen($e['session']) >= 1 && strlen($e['session']) <= 64
            && is_string($e['from'] ?? null) && preg_match(Device::ID_PATTERN, $e['from'])
            && is_string($e['to'] ?? null) && preg_match(Device::ID_PATTERN, $e['to'])
            && is_int($e['seq'] ?? null) && $e['seq'] >= 0
            && is_int($e['ts'] ?? null)
            && is_string($e['sig'] ?? null) && $e['sig'] !== ''
            && is_array($e['body'] ?? null);
    }
}
