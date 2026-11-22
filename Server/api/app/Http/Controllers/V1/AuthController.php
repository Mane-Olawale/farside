<?php

namespace App\Http\Controllers\V1;

use App\Http\Controllers\Controller;
use App\Models\Account;
use App\Models\AuditEvent;
use App\Models\Device;
use App\Services\AppleIdentityVerifier;
use App\Services\InvalidAppleToken;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\Rule;

class AuthController extends Controller
{
    /**
     * POST /v1/auth/apple: exchanges an Apple identity token for this device's token, and
     * registers the device with its public key (plan section 13). A device id belongs to one
     * account and one key for good; a new key means a new id.
     */
    public function apple(Request $request, AppleIdentityVerifier $apple): JsonResponse
    {
        $data = $request->validate([
            'identity_token' => ['required', 'string', 'max:4096'],
            'device.id' => ['required', 'string', 'regex:'.Device::ID_PATTERN],
            'device.name' => ['required', 'string', 'max:100'],
            'device.platform' => ['required', Rule::in(Device::PLATFORMS)],
            'device.model' => ['nullable', 'string', 'max:64'],
            'device.os_version' => ['nullable', 'string', 'max:32'],
            'device.app_version' => ['nullable', 'string', 'max:32'],
            'device.public_key' => ['required', 'string', 'max:100'],
        ]);
        $fields = $data['device'];
        $fingerprint = Device::fingerprint($fields['public_key']);
        if ($fingerprint === null) {
            return response()->json(['message' => 'The public key is not a P-256 point.'], 422);
        }

        try {
            $subject = $apple->subject($data['identity_token']);
        } catch (InvalidAppleToken) {
            return response()->json(['message' => 'Sign in with Apple could not be verified.'], 401);
        }

        return DB::transaction(function () use ($subject, $fields, $fingerprint, $request) {
            $account = Account::firstOrCreate(['apple_subject' => $subject]);
            $device = Device::find($fields['id']);
            if ($device && ($device->account_id !== $account->id || $device->public_key !== $fields['public_key'])) {
                return response()->json(['message' => 'This device id is already registered.'], 409);
            }
            if ($device?->revoked_at) {
                return response()->json(['message' => 'This device was removed from the account.'], 403);
            }
            $created = $device === null;
            $device ??= new Device(['id' => $fields['id']]);
            $device->account_id = $account->id;
            $device->fill([...$fields, 'key_fingerprint' => $fingerprint]);
            $device->last_seen_at = now();
            $device->save();

            // One token per device: signing in again replaces it.
            $device->tokens()->delete();
            $token = $device->createToken('device')->plainTextToken;

            AuditEvent::record($account->id, $device->id, $created ? 'device_registered' : 'sign_in', $request->ip());

            return response()->json([
                'token' => $token,
                'account' => ['id' => $account->id],
                'device' => $device->summary(),
            ], $created ? 201 : 200);
        });
    }
}
