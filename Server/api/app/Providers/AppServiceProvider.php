<?php

namespace App\Providers;

use App\Services\AppleIdentityVerifier;
use App\Services\IceServers;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(AppleIdentityVerifier::class, fn () => new AppleIdentityVerifier(
            config('services.apple.audiences'),
        ));
        $this->app->singleton(IceServers::class, fn () => new IceServers(config('services.turn')));
    }

    /** Plan section 13, limits and failure behavior. */
    public function boot(): void
    {
        RateLimiter::for('sign-in', fn (Request $request) => Limit::perMinute(5)->by($request->ip()));
        RateLimiter::for('sessions', fn (Request $request) => Limit::perMinute(10)->by($request->user()?->id ?: $request->ip()));
    }
}
