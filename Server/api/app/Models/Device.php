<?php

namespace App\Models;

use Illuminate\Auth\Authenticatable as AuthenticatableTrait;
use Illuminate\Contracts\Auth\Authenticatable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Foundation\Auth\Access\Authorizable;
use Laravel\Sanctum\HasApiTokens;

/**
 * An iPad or a Mac on an account. It authenticates with its own token, and its id and public
 * key come from the device itself (plan sections 13 and 14).
 */
class Device extends Model implements Authenticatable
{
    use AuthenticatableTrait, Authorizable, HasApiTokens;

    public const PLATFORMS = ['iPadOS', 'macOS'];

    /** dev_ and 26 Crockford base32 characters, as the apps make them. */
    public const ID_PATTERN = '/^dev_[0-9A-HJKMNP-TV-Z]{26}$/';

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'id', 'name', 'platform', 'model', 'os_version', 'app_version', 'public_key', 'key_fingerprint',
    ];

    protected $hidden = ['remember_token'];

    protected function casts(): array
    {
        return [
            'last_seen_at' => 'datetime',
            'revoked_at' => 'datetime',
        ];
    }

    public function account(): BelongsTo
    {
        return $this->belongsTo(Account::class);
    }

    public function scopeActive(Builder $query): void
    {
        $query->whereNull('revoked_at');
    }

    public function isHost(): bool
    {
        return $this->platform === 'macOS';
    }

    /** No password: devices sign in with Apple and then use their token. */
    public function getAuthPassword(): string
    {
        return '';
    }

    public function getRememberTokenName(): string
    {
        return '';
    }

    /**
     * The fingerprint the apps show: SHA-256 of the uncompressed point, hex. Null when the
     * key is not a 65-byte uncompressed P-256 point.
     */
    public static function fingerprint(string $base64Key): ?string
    {
        $raw = base64_decode($base64Key, true);
        if ($raw === false || strlen($raw) !== 65 || $raw[0] !== "\x04") {
            return null;
        }

        return hash('sha256', $raw);
    }

    /** What other devices on the account see. */
    public function summary(): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'platform' => $this->platform,
            'model' => $this->model,
            'os_version' => $this->os_version,
            'app_version' => $this->app_version,
            'public_key' => $this->public_key,
            'key_fingerprint' => $this->key_fingerprint,
            'last_seen_at' => $this->last_seen_at?->toIso8601String(),
        ];
    }
}
