<?php

use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
        // Paths as in plan section 13: /v1/..., not /api/v1/...
        apiPrefix: '',
    )
    // POST /broadcasting/auth, with the device's token.
    ->withBroadcasting(__DIR__.'/../routes/channels.php', ['middleware' => ['auth:sanctum']])
    ->withMiddleware(function (Middleware $middleware): void {
        //
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        // Every response is JSON: there are no pages.
        $exceptions->shouldRenderJsonWhen(fn (Request $request) => true);
    })->create();
