<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Refuses a revoked device even if a token survived, and records when a device last called the
 * API, at most once a minute.
 */
class ActiveDevice
{
    public function handle(Request $request, Closure $next): Response
    {
        $device = $request->user();
        if ($device?->revoked_at) {
            return response()->json(['message' => 'This device was removed from the account.'], 401);
        }
        if ($device && (! $device->last_seen_at || $device->last_seen_at->lt(now()->subMinute()))) {
            $device->forceFill(['last_seen_at' => now()])->saveQuietly();
        }

        return $next($request);
    }
}
