<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Modules\HarborPine\Services\RefundRepair;

class RepairRefundsCommand extends Command
{
    protected $signature = 'hp:repair-refunds {--dry-run : list the affected orders only}';

    protected $description = 'Harbor & Pine Market: settle fully returned promotional orders left at a negative total (idempotent).';

    public function handle( RefundRepair $repair )
    {
        $this->line( json_encode( $repair->run( (bool) $this->option( 'dry-run' ) ), JSON_PRETTY_PRINT ) );

        return self::SUCCESS;
    }
}
