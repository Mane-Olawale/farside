<?php

namespace App\Services;

use RuntimeException;

/** A Sign in with Apple token that did not verify. */
class InvalidAppleToken extends RuntimeException {}
