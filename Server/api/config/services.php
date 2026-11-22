<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Resend, Postmark, AWS, and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'key' => env('POSTMARK_API_KEY'),
    ],

    'resend' => [
        'key' => env('RESEND_API_KEY'),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],

    // Sign in with Apple: tokens must be issued for one of the apps (plan section 13).
    'apple' => [
        'audiences' => array_values(array_filter(explode(',', (string) env('APPLE_AUDIENCES', '')))),
    ],

    // STUN and TURN (plan section 13, TURN credentials). Provider: none, cloudflare or coturn.
    'turn' => [
        'provider' => env('TURN_PROVIDER', 'none'),
        // 12 hours: longer than any session (plan section 12).
        'ttl' => (int) env('TURN_TTL', 43200),
        'stun' => array_values(array_filter(explode(',', (string) env('STUN_URLS', 'stun:stun.cloudflare.com:3478')))),
        'cloudflare_key_id' => env('CLOUDFLARE_TURN_KEY_ID'),
        'cloudflare_api_token' => env('CLOUDFLARE_TURN_API_TOKEN'),
        'coturn_urls' => array_values(array_filter(explode(',', (string) env('COTURN_URLS', '')))),
        'coturn_secret' => env('COTURN_SECRET'),
    ],

];
