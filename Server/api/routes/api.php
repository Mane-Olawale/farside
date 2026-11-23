<?php

use App\Http\Controllers\V1\AccountController;
use App\Http\Controllers\V1\AuthController;
use App\Http\Controllers\V1\DeviceController;
use App\Http\Controllers\V1\SessionController;
use App\Http\Controllers\V1\SignalController;
use App\Http\Middleware\ActiveDevice;
use Illuminate\Support\Facades\Route;

// Plan section 13, API.
Route::prefix('v1')->group(function () {
    Route::post('auth/apple', [AuthController::class, 'apple'])->middleware('throttle:sign-in');

    Route::middleware(['auth:sanctum', ActiveDevice::class])->group(function () {
        Route::get('devices', [DeviceController::class, 'index']);
        Route::post('devices', [DeviceController::class, 'register']);
        Route::patch('devices/{id}', [DeviceController::class, 'update']);
        Route::delete('devices/{id}', [DeviceController::class, 'destroy']);

        Route::post('sessions', [SessionController::class, 'store'])->middleware('throttle:sessions');
        Route::post('sessions/{id}/events', [SessionController::class, 'event']);
        Route::get('ice-servers', [SessionController::class, 'iceServers']);

        Route::post('signal', SignalController::class);

        Route::delete('account', [AccountController::class, 'destroy']);
    });
});
