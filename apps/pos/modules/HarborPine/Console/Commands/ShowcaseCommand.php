<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Modules\HarborPine\Services\Showcase;

class ShowcaseCommand extends Command
{
    protected $signature = 'hp:showcase {action : enable|disable}';

    protected $description = 'Harbor & Pine Market: configure and enable/disable read-only visitor access.';

    public function handle()
    {
        $this->line( json_encode( Showcase::configure( $this->argument( 'action' ) === 'enable' ), JSON_PRETTY_PRINT ) );

        return self::SUCCESS;
    }
}
