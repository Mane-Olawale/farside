<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Plan section 13, data model. Metadata only: no session descriptions, candidates, screen
 * content, input or clipboard is ever stored.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('accounts', function (Blueprint $table) {
            $table->ulid('id')->primary();
            // Apple's stable user id for this team. No email, name or other profile data.
            $table->string('apple_subject')->unique();
            $table->timestamps();
        });

        Schema::create('devices', function (Blueprint $table) {
            // Made on the device: dev_ and 26 Crockford base32 characters.
            $table->string('id', 30)->primary();
            $table->foreignUlid('account_id')->constrained()->cascadeOnDelete();
            $table->string('name', 100);
            $table->string('platform', 16);
            $table->string('model', 64)->nullable();
            $table->string('os_version', 32)->nullable();
            $table->string('app_version', 32)->nullable();
            // The 65-byte uncompressed P-256 point, base64. Public keys only.
            $table->string('public_key', 100);
            $table->string('key_fingerprint', 64);
            $table->timestamp('last_seen_at')->nullable();
            $table->timestamp('revoked_at')->nullable();
            $table->timestamps();
        });

        Schema::create('sessions', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('account_id')->constrained()->cascadeOnDelete();
            $table->string('client_device_id', 30);
            $table->string('host_device_id', 30);
            $table->timestamp('started_at');
            $table->timestamp('connected_at')->nullable();
            $table->timestamp('ended_at')->nullable();
            $table->string('path_type', 32)->nullable();
            $table->string('end_reason', 32)->nullable();
            $table->unsignedInteger('avg_bitrate')->nullable();
            $table->unsignedInteger('avg_rtt')->nullable();
            $table->index(['host_device_id', 'started_at']);
        });

        Schema::create('audit_events', function (Blueprint $table) {
            $table->id();
            $table->foreignUlid('account_id')->constrained()->cascadeOnDelete();
            $table->string('device_id', 30)->nullable();
            $table->string('type', 32);
            $table->string('ip', 45)->nullable();
            $table->timestamp('created_at');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('audit_events');
        Schema::dropIfExists('sessions');
        Schema::dropIfExists('devices');
        Schema::dropIfExists('accounts');
    }
};
