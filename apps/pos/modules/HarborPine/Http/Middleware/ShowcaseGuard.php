<?php
namespace Modules\HarborPine\Http\Middleware;

use App\Models\Register;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Modules\HarborPine\Services\Showcase;
use Symfony\Component\HttpFoundation\Response;

/**
 * Enforces the read-only visitor mode on every web and API request:
 *  - visitors cannot write anything (all non-GET requests refused); submitting an order from the POS
 *    screen answers with an explicit "checkout preview: not saved" message (nothing is persisted);
 *  - administrative areas and uploaded media are refused even for reading;
 *  - visitor HTML pages get a permanent read-only banner; the sign-in page offers the demo entry.
 */
class ShowcaseGuard
{
    private const BLOCKED_PREFIXES = [
        'dashboard/settings', 'dashboard/modules', 'dashboard/users', 'dashboard/profile', 'dashboard/medias', 'dashboard/roles',
        'api/settings', 'api/modules', 'api/medias', 'api/reports/compute', 'api/users',
    ];

    public function handle( Request $request, Closure $next ): Response
    {
        $user = Auth::user();
        if ( $user === null && Auth::guard( 'sanctum' )->check() ) {
            $user = Auth::guard( 'sanctum' )->user();
        }
        $visitor = Showcase::isVisitor( $user );
        if ( $visitor ) {
            $path = ltrim( $request->path(), '/' );
            if ( ! in_array( $request->method(), [ 'GET', 'HEAD', 'OPTIONS' ], true ) && ! $this->readOnlyPost( $request, $path ) ) {
                $preview = $request->isMethod( 'POST' ) && preg_match( '#^api/orders/?$#', $path );

                return $this->refuse( $request, $preview
                    ? 'Checkout preview: in the read-only demo this order was not saved and stock was not changed.'
                    : 'This is a read-only demo: changes are disabled.' );
            }
            foreach ( self::BLOCKED_PREFIXES as $prefix ) {
                if ( str_starts_with( $path, $prefix ) ) {
                    return $this->refuse( $request, 'This area is not part of the read-only demo.' );
                }
            }
            if ( $request->isMethod( 'GET' ) && $path === 'api/cash-registers/used' ) {
                return $this->previewRegister();
            }
        }

        $response = $next( $request );

        return $this->decorate( $request, $response, $visitor );
    }

    /**
     * NexoPOS fetches report data and runs searches with POST. These endpoints only read; anything
     * else (report recomputation, bulk actions, preloads, creates) stays refused.
     */
    private const READ_ONLY_POSTS = [
        '#^api/reports/(sale-report|sold-stock-report|profit-report|transactions|annual-report|payment-types|products-report|low-stock|stock-report|product-history-combined|customers-statement/\d+)$#',
        '#^api/(products|customers)/search$#',
        '#^api/pos/catalog/products/search$#',
        '#^api/procurements/products/(search-product|search-procurement-product)$#',
    ];

    private function readOnlyPost( Request $request, string $path ): bool
    {
        if ( ! $request->isMethod( 'POST' ) ) {
            return false;
        }
        foreach ( self::READ_ONLY_POSTS as $pattern ) {
            if ( preg_match( $pattern, $path ) ) {
                return true;
            }
        }

        return false;
    }

    /**
     * The POS screen asks which register the signed-in user has opened; visitors cannot open one (that is a
     * write), so they get the store's first register as a read-only preview. Nothing is stored: every
     * register action and the order submission stay refused.
     */
    private function previewRegister(): Response
    {
        $register = Register::orderBy( 'id' )->first();
        if ( ! $register instanceof Register ) {
            return response()->json( [ 'status' => 'error', 'message' => 'No register available for the preview.' ], 403 );
        }
        $data = $register->toArray();
        $data['status'] = Register::STATUS_OPENED;
        $data['name'] = $register->name . ' (preview)';

        return response()->json( [ 'status' => 'success', 'message' => 'Checkout preview register (read-only).', 'data' => [ 'register' => $data ] ] );
    }

    private function refuse( Request $request, string $message ): Response
    {
        if ( $request->expectsJson() || str_starts_with( $request->path(), 'api/' ) ) {
            return response()->json( [ 'status' => 'error', 'message' => $message, 'code' => 'showcase_read_only' ], 403 );
        }

        return response( $this->page( $message ), 403 );
    }

    private function decorate( Request $request, Response $response, bool $visitor ): Response
    {
        $type = (string) $response->headers->get( 'Content-Type' );
        if ( ! str_contains( $type, 'text/html' ) || $response->getStatusCode() !== 200 ) {
            return $response;
        }
        $html = $response->getContent();
        if ( ! is_string( $html ) || ! str_contains( $html, '</body>' ) ) {
            return $response;
        }
        if ( $visitor ) {
            $html = str_replace( '</body>', $this->banner() . '</body>', $html );
        } elseif ( ltrim( $request->path(), '/' ) === 'sign-in' && Showcase::enabled() ) {
            $html = str_replace( '</body>', $this->entry() . '</body>', $html );
        } else {
            return $response;
        }
        $response->setContent( $html );

        return $response;
    }

    private function banner(): string
    {
        // NexoPOS notices (#snack-wrapper) also sit at the bottom centre: keep them above and clear of the banner.
        return '<style>#snack-wrapper{z-index:100000!important;padding-bottom:44px!important}</style>'
            . '<div id="hp-showcase-banner" role="status" style="position:fixed;left:50%;bottom:12px;transform:translateX(-50%);z-index:99999;max-width:calc(100vw - 24px);padding:6px 14px;border-radius:999px;background:rgba(17,24,39,.92);color:#fff;font:12px/1.4 system-ui,sans-serif;box-shadow:0 4px 14px rgba(0,0,0,.25);text-align:center">'
            . 'Read-only demo &middot; Harbor &amp; Pine Market (fictional) &middot; live simulated activity &middot; changes are disabled &middot; <a href="/sign-out" style="color:#9ae6b4">Leave</a></div>';
    }

    private function entry(): string
    {
        return '<div id="hp-showcase-entry" style="position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:99999;text-align:center;font:14px/1.4 system-ui,sans-serif">'
            . '<a href="/showcase/enter" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#0f766e;color:#fff;text-decoration:none;box-shadow:0 4px 14px rgba(0,0,0,.2)">Explore the live demo (read-only)</a>'
            . '<div style="margin-top:6px;color:#4b5563;font-size:12px">Fictional store, simulated activity. No sign-up needed.</div></div>';
    }

    private function page( string $message ): string
    {
        return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Read-only demo</title></head>'
            . '<body style="font:16px/1.5 system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0;color:#111827"><main style="max-width:28rem;padding:24px;text-align:center">'
            . '<h1 style="font-size:1.25rem">Read-only demo</h1><p>' . e( $message ) . '</p><p><a href="/dashboard">Back to the dashboard</a></p></main></body></html>';
    }
}
