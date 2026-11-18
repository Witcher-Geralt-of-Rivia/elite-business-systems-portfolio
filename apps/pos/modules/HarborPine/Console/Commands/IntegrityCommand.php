<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Modules\HarborPine\Services\Integrity;

class IntegrityCommand extends Command
{
    protected $signature = 'hp:integrity {--json : machine-readable output} {--only= : comma-separated check names}';

    protected $description = 'Harbor & Pine Market: run the data-integrity checks and print record counts and reconciliation totals.';

    public function handle()
    {
        $checks = Integrity::run( array_filter( explode( ',', (string) $this->option( 'only' ) ) ) );
        $failing = array_filter( $checks, fn( $n ) => $n > 0 );
        $report = [ 'checks' => count( $checks ), 'failing' => $failing, 'results' => $checks ] + Integrity::profile() + [ 'seconds' => Integrity::$timings ];
        if ( $this->option( 'json' ) ) {
            $this->line( json_encode( $report, JSON_PRETTY_PRINT ) );
        } else {
            foreach ( $checks as $name => $n ) {
                $this->line( sprintf( '%s %-36s %d', $n === 0 ? 'PASS' : 'FAIL', $name, $n ) );
            }
            $this->line( json_encode( [ 'counts' => $report['counts'], 'money' => $report['money'], 'range' => $report['range'] ], JSON_PRETTY_PRINT ) );
        }

        return $failing ? self::FAILURE : self::SUCCESS;
    }
}
