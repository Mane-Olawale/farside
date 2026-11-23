<?php

namespace App\Http\Controllers\V1;

use App\Http\Controllers\Controller;
use App\Models\Account;
use App\Models\Device;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class AccountController extends Controller
{
    /** DELETE /v1/account: the account and everything stored about it. */
    public function destroy(Request $request): JsonResponse
    {
        $accountId = $request->user()->account_id;
        DB::transaction(function () use ($accountId) {
            Device::where('account_id', $accountId)->get()->each(fn (Device $d) => $d->tokens()->delete());
            Account::whereKey($accountId)->delete();
        });

        return response()->json(status: 204);
    }
}
