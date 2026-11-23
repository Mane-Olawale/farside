<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * One Apple ID's devices. No password and no profile data (plan section 13).
 */
class Account extends Model
{
    use HasUlids;

    protected $fillable = ['apple_subject'];

    public function devices(): HasMany
    {
        return $this->hasMany(Device::class);
    }

    public function sessions(): HasMany
    {
        return $this->hasMany(Session::class);
    }
}
