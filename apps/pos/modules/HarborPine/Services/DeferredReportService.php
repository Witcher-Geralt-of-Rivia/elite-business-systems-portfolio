<?php
namespace Modules\HarborPine\Services;

use App\Models\DashboardDay;
use App\Models\DashboardMonth;
use App\Services\ReportService;
use Carbon\Carbon;

/**
 * Used ONLY while backfilling history: NexoPOS recomputes the whole day's dashboard after every
 * order and every accounting line (~50 aggregate queries per sale). During a backfill those
 * intermediate results are immediately superseded, so they are deferred and the real
 * ReportService rebuilds every day and month once, in chronological order (`ns:report --compute`).
 * All other ReportService behaviour (stock-history combined report, adjustments) is unchanged.
 */
class DeferredReportService extends ReportService
{
    public function computeDayReport( ?string $dateStart = null, ?string $dateEnd = null ): DashboardDay
    {
        return new DashboardDay;
    }

    public function computeDashboardMonth( ?Carbon $todayCarbon = null ): DashboardMonth
    {
        return new DashboardMonth;
    }
}
