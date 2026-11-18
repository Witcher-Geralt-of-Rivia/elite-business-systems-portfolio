<?php
/**
 * One-time NexoPOS store setup without putting the admin password on the command line.
 *   POS_ADMIN_PASSWORD=... php setup-store.php C:\srv\portfolio\pos\app
 * Reads POS_STORE_NAME, POS_ADMIN_USERNAME, POS_ADMIN_EMAIL, POS_ADMIN_PASSWORD from the environment
 * and calls `ns:setup` in-process (options never appear in the process list).
 */
$app = $argv[1] ?? null;
if (! $app || ! is_file($app . '/artisan')) {
    fwrite(STDERR, "usage: php setup-store.php <nexopos app dir>\n");
    exit(2);
}
foreach (['POS_STORE_NAME', 'POS_ADMIN_USERNAME', 'POS_ADMIN_EMAIL', 'POS_ADMIN_PASSWORD'] as $var) {
    if (! getenv($var)) {
        fwrite(STDERR, "missing environment variable $var\n");
        exit(2);
    }
}
chdir($app);
require $app . '/vendor/autoload.php';
$laravel = require $app . '/bootstrap/app.php';
$kernel = $laravel->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();
$status = Illuminate\Support\Facades\Artisan::call('ns:setup', [
    '--store_name' => getenv('POS_STORE_NAME'),
    '--admin_username' => getenv('POS_ADMIN_USERNAME'),
    '--admin_email' => getenv('POS_ADMIN_EMAIL'),
    '--admin_password' => getenv('POS_ADMIN_PASSWORD'),
    '--language' => 'en',
]);
echo Illuminate\Support\Facades\Artisan::output();
exit($status);
