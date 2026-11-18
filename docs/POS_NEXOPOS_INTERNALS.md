# NexoPOS 6.3.0 internals for a simulator module

Reference for engineers writing a NexoPOS **module** that generates retail history and live activity through NexoPOS's own services, without raw SQL.

- Source read: `C:\srv\portfolio\pos\app` (NexoPOS `6.3.0`, `config/nexopos.php:12`; Laravel 12).
- Citations use `path:line` relative to that directory. Abbreviations: `OS` = `app/Services/OrdersService.php`, `PS` = `app/Services/ProductService.php`, `PRS` = `app/Services/ProcurementService.php`, `CRS` = `app/Services/CashRegistersService.php`, `RS` = `app/Services/ReportService.php`, `MS` = `app/Services/ModulesService.php`.
- This document comes from reading the code only. Nothing was executed. Anything not confirmed in the code is marked **UNVERIFIED**.
- Environment here: `QUEUE_CONNECTION=sync`, `CACHE_DRIVER=file`, `TELESCOPE_ENABLED=false` (`.env:15-25`). Every queued job below therefore runs inline, inside the caller's request.

---

## 1. Module system

### Layout (discovered by `MS::__init`, `MS:146-351`)
```
modules/<Ns>/                      # folder name MUST equal <namespace> (psr-4-compliance, MS:301; disabled otherwise MS:533-537)
  config.xml                       # required, else folder ignored (MS:166, MS:349)
  <Ns>Module.php                   # required entry class Modules\<Ns>\<Ns>Module (MS:242, MS:280, MS:345)
  Providers/*.php                  # Modules\<Ns>\Providers\<File>; register()/boot() called if it extends Illuminate ServiceProvider (MS:367-397)
  Console/Commands/*.php           # auto-registered artisan commands, class = Modules\<path> (MS:285-295, ModulesServiceProvider.php:75-81, :39)
  Console/Kernel.php               # Modules\<Ns>\Console\Kernel::schedule(Schedule) (bootstrap/modules-schedule.php:19-37)
  Migrations/*.php                 # module migrations (MS:1779-1803)
  Routes/web.php, Routes/api.php   # app/Classes/ModuleRouting.php:26-80
  Listeners/*.php                  # Laravel event discovery (app/Providers/EventServiceProvider.php:23-40)
  Config/*.php                     # merged into config('modules.<Ns>.<file>.*') (MS:562-573)
  Resources/Views                  # view namespace <Ns> (MS:559)
  Lang/*.json, Public/ (symlinked to public/modules), vendor/autoload.php (auto-required, MS:545-549)
```

### `config.xml` (template `resources/views/generate/modules/config.blade.php`; parser `MS:166-235`)
```xml
<?xml version="1.0"?>
<module>
  <namespace>RetailSim</namespace>
  <version>1.0</version>
  <author>...</author>
  <name>Retail Simulator</name>
  <description><locale lang="en">...</locale></description>
  <core min-version="6.3.0"/>                                   <!-- optional, checked on enable MS:1515-1534 -->
  <requires><dependency namespace="Other" min-version="1.0">Other</dependency></requires>  <!-- optional -->
</module>
```

### Entry class and provider (templates `main.blade.php`, `providers.blade.php`)
```php
namespace Modules\RetailSim;
class RetailSimModule extends \App\Services\Module { public function __construct() { parent::__construct(__FILE__); } }

namespace Modules\RetailSim\Providers;
class RetailSimServiceProvider extends \Illuminate\Support\ServiceProvider { public function register() {} public function boot() {} }
```
- Providers are instantiated by `MS::triggerServiceProviders`, which receives `$config` by value. `register()` and `boot()` therefore each get a **fresh instance** (MS:367-397). Do not keep state on the provider object.
- Module listeners are discovered by type-hinting the event in `handle()`. The app's provider only adds the module `Listeners` paths (EventServiceProvider.php:23-35). The core `app/Listeners` come from the framework default `withEvents()` (vendor `ApplicationBuilder.php:98-117`). If `event:cache` is used, re-cache after enabling the module.

### Scheduled task
`bootstrap/app.php:25-27` includes `bootstrap/modules-schedule.php`, which instantiates `Modules\<Ns>\Console\Kernel(app(), app('events'))` and calls `->schedule($schedule)` **from outside the class** (modules-schedule.php:30-34).
- The generated template declares `protected function schedule(...)` (`resources/views/generate/modules/kernel.blade.php`). A protected method makes that call fail with "Call to protected method". **Declare it `public`.**
- `Routes/console.php` is detected (`console-file`, MS:245, MS:248), but no loader includes it. The only reference is `ModuleDetailsCommand.php:95-99`. Put scheduling in `Console/Kernel.php`.
- The scheduler needs the system cron: `php artisan schedule:run` every minute. Core jobs are in `routes/console.php:34-112`.

### Migrations
- Each file is a `return new class extends Migration {...}` or a named class in `Modules\<Ns>\Migrations` (MS:1378-1405; template `migration.blade.php`).
- An optional `const DEPENDENCIES = ['OtherNs']` skips the migration until that module is enabled (MS:1793-1797).
- Pending files are sorted by name (MS:1770). Migrated files are recorded in `ModuleMigration` (MS:1844-1856). The migrated list is cached for 24h (MS:1740).

### Artisan
| Command | Source | Notes |
|---|---|---|
| `make:module -n --namespace=RetailSim --name=".." --author=".." --description=".."` | GenerateModuleCommand.php:24-30, MS:1927-1988 | Scaffolds the folders, config.xml, the entry class and `Migrations/DatabaseMigration.php` |
| `modules:enable RetailSim` | ModuleEnableCommand.php:16 → MS:1483-1648 | Checks PSR-4, min-version and dependencies, php-parses the entry and providers, boots them, stores option `enabled_modules`, symlinks, runs `cache:clear`. **Does not run migrations.** |
| `modules:migrate RetailSim` | ModulesMigrateCommand.php:17-70 | Runs the pending module migrations |
| `modules:disable`, `modules:remove`, `modules:list`, `modules:symlink` | Module*Command.php | |
| `modules:command|controller|migration|model|provider|kernel|listener|event|job|request|settings|mail <Ns> ...` | ModuleCommandGenerator.php etc. | Generators |
- `NS_LOCK_MODULES=true` blocks enable and disable (MS:1916-1921). `AUTOLOAD_MODULES=A,B` boots the listed modules without enabling them (MS:608-645). Such modules cannot be "enabled" (MS:1505-1511).
- Example modules: `modules/` is **empty** in this install, and no fixture module exists under `tests/`. `tests/Feature/UploadModuleTest.php` only references config.xml.
- Closest in-tree reference for the service calls: `app/Services/DemoService.php` together with `app/Services/DemoCoreService.php`, which back `ns:reset --mode=wipe_plus_grocery`. They create products, a procurement and orders through the services.

---

## 2. Catalog setup (all services resolve from the container; most stamp `author_id = Auth::id()`, so authenticate first, see §4.6)

| Entity | Call | Payload (required unless marked `?`) |
|---|---|---|
| Tax group | `TaxService::createTaxGroup($f)` (TaxService.php:133) | `['name'=>string,'description'=>string]`. `description` is read without `??`, so pass it. |
| Tax | `TaxService::createTax($f)` (:151) | `['name'=>string,'rate'=>float /*percent*/,'tax_group_id'=>int,'description'=>string]` |
| Unit group | `UnitService::createGroup($d)` (UnitService.php:19) | `['name'=>string,'description'?=>string]` |
| Unit | `UnitService::createUnit($d)` (:94) | `['name','identifier'/*UNIQUE, create_units_table.php:24*/,'group_id'=>int,'value'=>float/*base multiplier*/,'base_unit'=>bool,'description'?]`. All keys are copied onto the model. `base_unit === true` resets the other units of the group (:103). |
| Category | `ProductCategoryService::create($d)` (ProductCategoryService.php:48) | `['name', 'parent_id'?, 'description'?, 'preview_url'?, 'displays_on_pos'?=true, 'author_id'?]` |
| Provider | `ProviderService::create($d)` (ProviderService.php:25) | Columns copied 1:1: `first_name`, `last_name`?, `email`? (**UNIQUE**, providers migration :24-26), `phone`?, `address_1`?, `address_2`?, `description`? |
| Customer group | `CustomerService::createGroup($f)` (CustomerService.php:684) | `['name','description'?,'reward_system_id'?,'minimal_credit_payment'?]`. Upserts by name. |
| Customer | `CustomerService::create($f)` (:151) | Every key except `address` becomes a `nexopos_users` column. Required: `username`, `email` (UNIQUE, users table :32; also prechecked :126-146), `password` (**already hashed**; not hashed here, unlike `CustomerCrud.php:318-322`), `first_name`?, `last_name`?, `group_id`?, `phone`?, `gender`?, `credit_limit_amount`?, plus **`address` key required** (:175): `['billing'=>[...],'shipping'=>[...]]` or `null`. The service assigns the role `nexopos.store.customer` (:197-207). Without that role the customer is invisible (global scope, `app/Models/Customer.php:55-65`). |
| Register | No service. Create the model as in DemoCoreService.php:132-145. | `name`, `status=Register::STATUS_CLOSED`, `author_id`, `description`? |
| Payment type | Model `PaymentType` as in SetupService.php:263-289 | `label`, `identifier` (unique by convention, not by DB), `author_id`, `active`=true, `readonly`?, `priority`?. Default identifiers: `cash-payment`, `bank-payment`, `account-payment` (`app/Models/OrderPayment.php:25-29`). |

### Product: `ProductService::create(array $data)` (PS:142 → `createSimpleProduct` PS:251)
```php
$productService->create([
  'name'             => 'Sparkling Water 1L',        // required
  'product_type'     => 'product',                   // required: 'product' | 'variable' (PS:185-191)
  'type'             => 'materialized',              // required key (PS:163): materialized|dematerialized|grouped (Product.php:74-78)
  'category_id'      => $catId,                      // required, must exist (PS:148)
  'status'           => 'available',                 // available|unavailable
  'stock_management' => 'enabled',                   // 'enabled'|'disabled' (Product.php:66-68). Only 'enabled' moves stock (PS:1323)
  'sku'              => 'SKU-0001',                  // optional; auto slug(category)--slug(name)--rand5 (PS:272-275)
  'barcode'          => '4006381333931',             // optional; auto-generated (PS:264-266)
  'barcode_type'     => 'ean13',                     // optional; default option ns_pos_default_barcode_type (PS:260-262)
  'tax_group_id'     => $taxGroupId,                 // optional
  'tax_type'         => 'inclusive',                 // 'inclusive'|'exclusive' (TaxService.php:338-357)
  'description'      => '',
  'units' => [                                       // required key (PS:170, PS:727-733)
    'unit_group'               => $unitGroupId,      // required
    'accurate_tracking'        => false, 'auto_cogs' => true,     // optional
    'default_purchase_unit_id' => null, 'scheduled_reorder_quantity' => null, // optional pair (PS:741-771)
    'selling_group' => [[                            // one entry per sellable unit; unit_id unique (PS:171-177)
      'unit_id'              => $pieceUnitId,        // required
      'sale_price_edit'      => 1.99,                // required, used as the sale price (PS:794-795)
      'wholesale_price_edit' => 1.50,                // required (PS:796)
      'barcode'?, 'low_quantity'?=>0, 'stock_alert_enabled'?=>false, 'cogs'?=>0, 'visible'?=>true,
      'convert_unit_id'?, 'preview_url'?, 'is_weighable'?=>false, 'scale_plu'? /*UNIQUE*/,
    ]],
  ],
  'images' => [],                                    // optional
]);
```
- All non-array keys are assigned directly as `nexopos_products` columns (PS:722-723). **An unknown key causes an SQL error.**
- `sale_price`, `sale_price_net`, `sale_price_gross` and `sale_price_tax` are derived from `sale_price_edit` and the tax group (TaxService.php:315-401). With `tax_type=exclusive`, `sale_price` = gross.
- Uniqueness: barcode and SKU are checked in the service only (PS:253-258, PS:281-286). `nexopos_products` has **no DB unique index** on `sku` or `barcode` (create_products_table.php:33-35). The unit-quantity barcode defaults to `"{product barcode}-{id}"`, but the id is still null at that point, which yields `"BARCODE-"` (PS:831). Pass an explicit `barcode` per selling unit.
- Stock starts at 0 (PS:788). Initial stock comes only from procurements or adjustments (§3).

---

## 3. Procurement: `ProcurementService::create(array $data)` (PRS:108 → PRS:116-185, wrapped in a DB transaction)
```php
$procurementService->create([
  'name'    => 'PO-2026-0001',                  // required KEY (PRS:149; null → auto name)
  'general' => [                                // every key is copied onto nexopos_procurements (PRS:151-153)
    'provider_id'        => $providerId,        // required (PRS:124-128)
    'payment_status'     => 'paid',             // 'paid'|'unpaid' (Procurement.php:76-81)
    'delivery_status'    => 'delivered',        // 'pending'|'delivered'|'stocked'|'draft'; ONLY 'delivered' adds stock
    'automatic_approval' => 1,                  // optional; with 'pending' + delivery_time → StockProcurementJob 00:05 (routes/console.php:66, PRS:979-1003)
    'delivery_time'?, 'invoice_reference'?, 'invoice_date'?, 'description'?,
    'created_at'?, 'updated_at'?,               // if either is set, timestamps are disabled (PRS:155-157): set BOTH
  ],
  'products' => [[                              // PRS:422-484 (all read without ?? unless noted)
    'product_id'           => $id,              // stock_management must be enabled, not grouped (PRS:438-444)
    'unit_id'              => $unitId,
    'quantity'             => 120,
    'purchase_price'       => 0.80,             // per unit
    'gross_purchase_price' => 0.86, 'net_purchase_price' => 0.80,
    'tax_type'             => 'inclusive', 'tax_value' => 0.06, 'tax_group_id'? => $tg,
    'total_purchase_price' => 96.00,            // caller computes; PRS never recomputes
    'expiration_date'?, 'convert_unit_id'?,
  ]],
]);
```

**Stock flow on delivery**
1. `ProcurementAfterCreateEvent` is dispatched (PRS:176).
2. Its listener `ProcurementAfterCreateEventListener` runs `refresh()` (cost, tax and value totals, PRS:611-660), then `ProviderService::computeSummary`, then `handleProcurement()` (Listeners/ProcurementAfterCreateEventListener.php).
3. `persistHandledProcurement` (PRS:905-962) runs only when `delivery_status === 'delivered'`. For each line it does three things:
   - `PS::saveHistory('procured', …)` writes a `ProductHistory` row with before/after quantities (PS:973-1019).
   - `PS::setQuantity()` (PS:1032-1052) updates the stock.
   - `generateBarcode()` (PRS:942) **writes a barcode image to disk for every line**.
4. The status then becomes `stocked` (PRS:956).
5. `ProcurementAfterHandledEvent` posts accounting entries for the receipt, plus the payment if `paid` (Listeners/ProcurementAfterHandledEventListener.php).

Delivery does **not** go through `PS::stockAdjustment`. `ProductHistory` `created` triggers COGS recompute and the combined daily stock report (Listeners/ProductHistoryAfterCreatedEventListener.php:26-27).

**Payment later.** `ProcurementController::setAsPaid` (`app/Http/Controllers/Dashboard/ProcurementController.php:136-149`) only does `payment_status='paid'; save()`. The model `updated` event, `ProcurementAfterUpdateEvent` (Procurement.php:88), then refreshes the procurement and re-handles it. **No approval workflow exists** beyond `automatic_approval` and `delivery_status`.

---

## 4. Orders: `OrdersService::create(array $fields, ?Order $order = null)` (OS:88, DB transaction ×3)

### 4.1 Payload
```php
$ordersService->create([
  'customer_id' => $customerId,                    // required, must be a store customer (OS:1840-1847)
  'type'        => ['identifier' => 'takeaway'],   // required; 'takeaway'|'delivery' (OS:1656, Order.php:75-77)
  'author_id'   => $cashierId,                     // optional; default Auth::id() (OS:1670)
  'register_id' => $registerId,                    // optional (OS:1659); see §6
  'created_at'  => '2026-03-14 18:42:07',          // optional; default ns()->date->getNow() (OS:1627). Use 'Y-m-d H:i:s'
  // 'updated_at' => DO NOT SEND, see the bug below
  'products' => [[
    'product_id'       => $pid,                    // or 'sku'; omit both for a "quick product" (OS:1302-1313)
    'unit_quantity_id' => $uqId,                   // required with product_id (ProductUnitQuantity::findOrFail, OS:1312)
    'unit_id'          => $unitId,                 // overwritten from the unit quantity (OS:1423)
    'quantity'         => 2,
    'unit_price'       => 1.99,                    // must equal sale_price_edit (normal mode) unless the user may override (OS:714-722)
    'mode'?            => 'normal',                // normal|wholesale|custom
    'discount_type'?   => 'percentage',            // 'flat' on a product is rejected (OS:693-699)
    'discount_percentage'? => 10, 'discount'? => 0.40,
    'name'?, 'total_price'? /*auto*/, 'tax_value'? /*auto*/, 'tax_group_id'?, 'tax_type'?,
  ]],
  'discount_type'       => 'percentage',           // optional: 'percentage'|'flat' (OS:672-689)
  'discount_percentage' => 5,  'discount' => 0,    // flat: 'discount' must be ≤ products total
  'shipping'?   => 0, 'subtotal'? => /*auto*/, 'total'? => /*auto*/,
  'tax_group_id'? , 'tax_type'?, 'taxes'? => [['tax_id'=>int,'name'=>string,'rate'=>float]], 'tax_value'?,
  'coupons'?    => [['coupon_id'=>int,'type'=>'percentage_discount'|'flat_discount','discount_value'=>float,'value'?=>float,'name'?,'code'?]],
  'payments'    => [['identifier' => 'cash-payment', 'value' => 3.98]],   // may be []
  'payment_status'? => 'hold',                     // only meaningful with no payment
  'addresses'?  => ['shipping'=>[...],'billing'=>[...]], // keys whitelisted at OS:766-806
  'note'?, 'title'?, 'instalments'?, 'final_payment_date'?,
]);
```
Working example: DemoCoreService.php:380-415. Response: `['status'=>'success','data'=>['order'=>Order]]` (OS:253-259).

### 4.2 Totals, what is computed and what to send
- Line totals are computed when absent: `total_price = unit_price*qty - discount` (OS:1550-1555). Line `tax_value` is computed from the product tax group (OS:1535-1545). `computeOrderProductTaxes` then **re-derives** it as `(price_gross - price_net)*qty` (TaxService.php:466-485).
- When the order has **no** `tax_group_id`, `computeProduct` sets `price_net = price_gross = unit_price` (OS:1576-1581). Static reading says product taxes then end up as **0** on `nexopos_orders_products`. **UNVERIFIED at runtime**: create one order and check before running a bulk load.
- Order `tax_value`: with `ns_pos_vat` set to `flat_vat` or `variable_vat` it is the sum of the `taxes[]` OrderTax rows (OS:503-516). Otherwise it is whatever you send (OS:1673). The dashboard `day_taxes` sums `orders.tax_value` (RS:152-161). **For `products_vat` or `disabled`, send `tax_value` yourself.**
- Payment validation compares `Σ payments` against `Σ line total_price + shipping - discount - coupons` (OS:996-1003). This **excludes exclusive taxes**. The stored total adds `tax_value` only if the order `tax_type === 'exclusive'` (OS:1101-1111).

### 4.3 Payment status rules (OS:956-1088)
- Every payment `identifier` must exist in `PaymentType::active()` (OS:1005-1029). `account-payment` requires `customer.account_amount >= value`.
- Outcomes:
  - `Σpay >= total` with at least 1 payment → `paid`.
  - `0 < Σpay < total` → `partially_paid`, blocked if option `ns_orders_allow_partial === false` (OS:1035-1039).
  - `0` → `unpaid`, blocked if `ns_orders_allow_incomplete === false` (OS:1040-1044); `hold` when `payment_status=hold` is sent.
- Any payment > 0 requires the permission `nexopos.make-payment.orders` (OS:1079-1081).
- `change = tendered - total` (OS:1118-1120).
- Add a payment later with `makeOrderSinglePayment(['identifier','value','register_id'?], $order)` (OS:863-934).

### 4.4 How stock is decremented
- `Order::$dispatchesEvents` and `dispatchableFieldsEvents['payment_status']` (Order.php:133-140) fire inside `NsModel::saveWithRelationships` (`app/Models/NsModel.php:71-122`). Note that it fires `created` **even for updates** (:117).
- The payment status changing from `null|hold|unpaid` to `paid|partially_paid|unpaid` triggers `saveOrderProductHistory` (Listeners/OrderAfterPaymentStatusChangedEventListener.php:21-26, OS:1247-1290). That runs `PS::stockAdjustment('sold', …)` for each line, which:
  - throws on negative stock (PS:1461-1475);
  - reduces the unit quantity;
  - writes a `ProductHistory` (PS:1606-1640);
  - fires `ProductAfterStockAdjustmentEvent` → accounting plus `HandleStockAdjustmentJob`.
- Stock is pre-checked against `nexopos_orders_storage` reservations (OS:1434-1504). Hold orders skip the check (OS:146-148).

### 4.5 Other side effects of creation
- `OrderAfterCreatedEventListener.php:36-45`: `SaveOrderSettingJob` (sync), then a chain:
  - `IncreaseCashierStatsJob` (users.total_sales);
  - `ProcessCustomerOwedAndRewardsJob`;
  - `ResolveInstalmentJob`;
  - `ComputeDayReportJob`;
  - `RecordOrderChangeJob` (register change).
- `AccountingJournalService::postFinalizedOrder` (OS:251; AccountingJournalService.php:162-188): journal dated `order.created_at`, plus `TransactionHistory` rows (:132-143).
- `OrderPaymentAfterCreatedEventListener.php:16-23`: accounting payment post, `TrackCashRegisterJob` (only if the option `ns_pos_registers_enabled === 'yes'`), and `StoreCustomerPaymentHistoryJob`.

### 4.6 Authentication from the CLI
`Auth::id()` and Gates are used throughout: payment permission (OS:1080), `ProductHistory.author_id` (PS:1636, column NOT NULL in products_history migration :36), `procurement.author_id` (PRS:159), refunds, registers and taxes.
- Core pattern: `Auth::login($user)` in console (GenerateTransactionsCommand.php:44-45; ResetCommand.php:97-104 uses `Auth::loginUsingId`).
- Gates are defined at boot only for the permissions that exist at that moment. The user's permission list is cached for 1h under `ns-all-permissions-{userId}` (CoreService.php:273-297). After changing roles, `Cache::forget('ns-all-permissions-'.$id)`.
- Log in as a user holding `nexopos.make-payment.orders`, for example the built-in `nexopos.store.cashier` (database/permissions/store-cashier-role.php:14-27). Pass `author_id` per order to spread sales across cashiers.
- POS-action permissions `nexopos.cart.*` apply only if listed in the option `ns_pos_action_permission_restricted_features` (UsersService.php:411-427).

### 4.7 Known bugs
- **OS:1662**: `updated_at` is formatted `'Y-m-d h:m:s'`, which gives a 12-hour clock and the *month* as minutes. **OS:1657** has the same bug for `final_payment_date`. Never send `updated_at`. Use `Carbon::setTestNow()` instead (§7) so the default `getNow()` is right.
- `DemoCoreService.php:378` and `tests/Traits/WithOrderTest.php:1267` use `'Y-m-d H:m:s'` (minutes = month). Do not copy them.
- `CustomerService::checkCouponExistence` calls `ns()->date->setTimeFrom()` (CustomerService.php:783-787), which **mutates the shared date singleton** for coupons that have valid hours.

---

## 5. Refunds: `OrdersService::refundOrder(Order $order, array $fields)` (OS:1849 → OS:1857-1981)
```php
$ordersService->refundOrder($order, [
  'payment'         => ['identifier' => 'cash-payment'],   // stored as order_refunds.payment_method (OS:1915)
  'refund_shipping' => false,                              // bool; strict === true needed to zero the shipping (OS:1916 vs OS:1934)
  'total'           => 3.98,                               // only read for 'account-payment' (credits the customer, OS:1955-1966)
  'products' => [[
    'id'          => $orderProduct->id,                    // OrderProduct id, NOT product id
    'quantity'    => 1,                                    // 0 < q ≤ remaining order-product qty (OS:1882-1898) → partial refunds OK
    'unit_price'  => 1.99,                                 // ≤ original unit_price (OS:1900-1909)
    'condition'   => 'unspoiled',                          // 'unspoiled' (restock) | 'damaged' (restock then 'defective' = waste) (OS:1988-1993, 2054-2079)
    'description' => '',                                   // required key (OS:2021)
  ]],
]);
```
- The order must be `paid`, `partially_paid`, `unpaid` or `partially_refunded` (OS:1859-1866).
- Records created: `OrderRefund` (total = Σ line refunds + shipping, OS:1911-1952), `OrderProductRefund` per line (OS:2019-2045), and `ProductHistory` `returned`, plus `defective` for damaged items (PS STOCK_INCREASE/REDUCE, ProductHistory.php:88-110).
- `OrderProduct.quantity` is reduced and its status set to `returned` (OS:2008-2013).
- Events:
  - `OrderAfterRefundedEvent`: accounting `postRefund` plus `RefreshOrderJob`, which recomputes the total and sets `refunded`/`partially_refunded` (OS:2266-2350), then reduces cashier stats and customer purchases (Listeners/OrderAfterRefundedEventListener.php).
  - `OrderAfterProductRefundedEvent` → `CreateExpenseFromRefundJob`.
- **No `RegisterHistory` `register-refund` row is ever written.** `ACTION_REFUND` only appears in labels (`grep`: CRS:375, CashRegistersController.php:198). Refunds do not reduce a register balance.

---

## 6. Cash registers (`CashRegistersService`, singleton, AppServiceProvider.php:103)
| Method | Line | Behaviour |
|---|---|---|
| `openRegister(Register $r, $amount, $description)` | CRS:18 | Requires status `closed`. Sets `opened` and `used_by=Auth::id()`, writes history `register-opening` with value `$amount` |
| `closeRegister(Register $r, $amount, $description)` | CRS:53 | Requires `opened`. History `register-closing`: `transaction_type` = `unchanged|positive|negative` comparing balance to the counted `$amount`, `balance_after = balance - amount`. Then `balance=0`, status `closed` |
| `cashIng(Register $r, float $amount, ?string $d)` | CRS:96 | `register-cash-in`, amount > 0 |
| `cashOut(Register $r, float $amount, ?string $d)` | CRS:203 | `register-cash-out`, requires balance ≥ amount |
| `saveOrderPayment(OrderPayment $p)` | CRS:131 | `register-order-payment` per payment of an order with `register_id`. **Every payment identifier counts, not just cash** |
| `saveOrderChange(Order $o)` | CRS:321 | `register-order-change` when paid and change > 0 |
| `refreshCashRegister(Register $r)` | CRS:271 | balance = Σ IN − Σ OUT since the last opening (by `created_at`) |
| `getZReport(Register $r)` | CRS:454 | Session report |

- The HTTP API is `POST api/cash-registers/{open|close|register-cash-in|register-cash-out}/{register}` with `amount` and `description` (CashRegistersController.php:75-114; routes/api/registers.php:13, permission `nexopos.use.registers`).
- Payments are linked to a register through `OrderPaymentAfterCreatedEventListener` → `TrackCashRegisterJob` → `saveOrderPayment`. This happens **only if** the option `ns_pos_registers_enabled === 'yes'` **and** `order.register_id` is set. `OrdersService::create` does **not** check that the register is open; only `makeOrderSinglePayment` does (OS:882-888).
- Balance: every `RegisterHistory` `created` triggers `updateRegisterBalance` synchronously (Listeners/CashRegisterHistoryAfterCreatedEventListener.php; CRS:251-264). IN actions add and OUT actions subtract (RegisterHistory.php:50-66). **It only changes while the register is `opened`.**

**Invariants to keep:**
- open, then orders, then close, in chronological order per register;
- `created_at` of the history rows comes from `now()`, so drive the clock (§7);
- close with `amount = $register->balance` to get `unchanged`.

Z-report quirks:
- `cashOnHand = opening + Σ cash payments − Σ change` (CRS:489-492).
- `difference = closing.value − (opening + Σtotal + Σshipping − Σdiscount)` (CRS:517-527). `total` already includes shipping and discount, so the difference is skewed whenever those are non-zero.

---

## 7. Time control and reports

**Clock.**
- `DateService extends Carbon` is a **singleton frozen at construction** (AppServiceProvider.php:89-97). Its timezone comes from option `ns_datetime_timezone`, which also sets `app.timezone`.
- `ns()->date` (and `->copy()`) returns that fixed instant. `ns()->date->getNow()` and `->now()` call `Carbon::now()`, so they **honour `Carbon::setTestNow()`**. Eloquent timestamps (`now()`) also honour it.
- `ns()->date->define($t, $tz='Europe/London')` re-constructs the singleton (DateService.php:57-60). **Pass the store timezone explicitly**, or it falls back to Europe/London.
- For backfill, set both per simulated event: `Carbon::setTestNow($t); ns()->date->define($t, ns()->option->get('ns_datetime_timezone','Europe/London'));`

| Timestamp source | Follows |
|---|---|
| `orders.created_at` default, `updated_at` default (OS:1627, 1662) | `setTestNow` (or pass `created_at`) |
| Child rows: order products, payments, ProductHistory, RegisterHistory, TransactionHistory `created_at` | `setTestNow` only. **Passing `created_at` on the order does not backdate them.** |
| Accounting journal `posted_at`, `trigger_date` | `order.created_at` (AccountingJournalService.php:180-181) |
| `ReportService::computeDayReport()` with no arguments (RS:75-91), `DashboardDay::forToday()` (DashboardDay.php:42-51) | **`ns()->date` instance**, not `setTestNow` |
| `computeDashboardMonth()` with no arguments (RS:93-150), combined stock history (RS:1172-1176) | `Carbon::now()` (setTestNow) |

**Precomputed tables:**
- `nexopos_dashboard_days` (`day_*` and cumulative `total_*` built from the previous day's row, RS:44-64, DashboardDay.php:71-80);
- `nexopos_dashboard_months` (sum of the days, RS:93-150);
- `nexopos_products_histories_combined` (RS:1091-1248);
- `nexopos_transactions_balance_days` and `nexopos_transactions_balance_months`.
- Product, category and customer *reports* are computed live from orders (`getProductsReports` RS:683, `getCategoryReports` RS:733, `getProductSalesDiff` RS:419). Customer totals live on `nexopos_users.purchases_amount` and `owed_amount`, updated by `ProcessCustomerOwedAndRewardsJob`.
- `day_income` and `day_expenses` come from `TransactionHistory.created_at` by account category (RS:220-244). Without `setTestNow`, backdated orders land income on *today*.

**What updates reports (all sync here):**
- `ComputeDayReportJob` per order create and update;
- `TransactionsHistoryAfterCreatedEventListener.php:30`: `computeDayReport()` **for every accounting line**;
- `DashboardDay` created or updated → `ComputeDashboardMonthReportJob` (DashboardDay*Listener.php:28; its `delay(10s)` is ignored on sync);
- wasted goods via `HandleStockAdjustmentJob` → `RS::handleStockAdjustment` (RS:168-218);
- `RefreshReportJob(date)` on order deletion (OrderAfterDeletedEventListener.php:40).
- Bug: `computeOrdersTaxes` accumulates `total_taxes` from **today's own** previous value, not yesterday's (RS:160). Every recompute inflates it.

**Commands:**
- `php artisan ns:report --compute --type=day --from=YYYY-MM-DD` recomputes every day from `--from` up to now (ComputeDailyReportCommand.php:16, :91-132). Use `--type=month` for months (:51-89).
- Run it after a backfill, chronologically. Because `total_*` chains from the previous day, out-of-order inserts need a full re-run.

**`ns:simulate`** (`app/Console/Commands/GenerateActivityCommand.php:17-89`):
- For each day over the last 5 months it includes **every `tests/Feature/*.php`** (except ResetTest), instantiates the class, calls its first method, and then does `$date->define($day)`.
- It depends on dev test classes and their side effects, and the first iteration runs at the real date.
- **Not suitable** for a production simulator. Whether it runs on a `--no-dev` install is **UNVERIFIED**.
- `ns:reset --mode=wipe_plus_grocery --with-procurements --with-sales` runs DemoService (ResetCommand.php:57-71). It creates 14 orders over 14 days by default (DemoCoreService.php:29-31).

---

## 8. Roles and permissions

**Built-in roles** (database/migrations/core/2020_06_20_000000_create_roles.php:34-38 including database/permissions/*-role.php):
- `user` (`manage.profile`);
- `admin`;
- `nexopos.store.administrator`;
- `nexopos.store.cashier`;
- `nexopos.store.customer` (Role.php:28-48).

**Naming scheme:**
- `nexopos.{create|read|update|delete}.{resource}`;
- special verbs: `nexopos.make-payment.orders`, `nexopos.refund.orders`, `nexopos.void.orders`, `nexopos.use.registers`, `nexopos.make.products-adjustments`;
- reports: `nexopos.reports.*`;
- POS: `nexopos.pos.*` and `nexopos.cart.*`;
- widgets: `nexopos.see.*-widget` (app/Widgets/*.php:15-21);
- core: `read.dashboard`, `manage.options`, `manage.modules`, `manage.profile`, `{create|read|update|delete}.{users|roles}`, `update.core`.
- Typo trap: the cashier role references `nexopos.*.orders-instaments` (store-cashier-role.php:22-24).

**Enforcement:**
- `NsRestrictMiddleware::arguments('perm')` on routes (app/Http/Middleware/NsRestrictMiddleware.php; e.g. routes/api/orders.php:8-39).
- `ns()->restrict([...])` in controllers (CoreService.php:105-127, which calls `Gate::allows`).
- CRUD classes use `$permissions = ['create','read','update','delete']` through `CrudService::allowedTo`. A missing key means **no check**, and `true` means anyone (CrudService.php:1588-1608).
- The dashboard group only requires login (routes/web-base.php:40-56).

**Creating a read-only role from a module migration or provider** (Role API: Role.php:97-212):
```php
$role = Role::firstOrNew(['namespace' => 'retailsim.readonly']);
$role->name = 'Read-only Visitor'; $role->locked = true; $role->description = 'Demo visitor'; $role->save();
$role->addPermissions([ /* list below */ ]);   // throws if a permission namespace does not exist (Role.php:120-130)
Cache::forget('ns-all-permissions-'.$user->id);
```
Assign it with `UsersService::setUserRole($user, [$role->id])` (UsersService.php:190).

**Grant:**
- `read.dashboard`
- `nexopos.see.sale-card-widget`, `nexopos.see.incomplete-sale-card-widget`, `nexopos.see.expense-card-widget`, `nexopos.see.orders-chart-widget`, `nexopos.see.orders-summary-widget`, `nexopos.see.best-customers-widget`, `nexopos.see.best-cashier-widget`
- `nexopos.read.products`, `nexopos.read.products-history`, `nexopos.read.products-units`, `nexopos.read.categories`, `nexopos.read.taxes`, `nexopos.read.providers`, `nexopos.read.procurements`
- `nexopos.read.orders`, `nexopos.read.orders-instalments`, `nexopos.read.customers`, `nexopos.read.customers-groups`, `nexopos.read.coupons`, `nexopos.read.rewards`
- `nexopos.read.registers`, `nexopos.read.registers-history`
- `nexopos.reports.sales`, `nexopos.reports.products-report`, `nexopos.reports.best_sales`, `nexopos.reports.yearly`, `nexopos.reports.customers`, `nexopos.reports.inventory`, `nexopos.reports.low-stock`, `nexopos.reports.stock-history`, `nexopos.reports.payment-types`, `nexopos.reports.customers-statement`, `nexopos.reports.transactions`
- Optional: `nexopos.read.transactions`, `nexopos.read.transactions-history`, `nexopos.read.transactions-account`

**Do NOT grant:**
- `manage.profile`: it lets a shared account change its password (routes/api/users.php:22).
- `manage.options`, `manage.modules`, `*.users`, `*.roles`.
- Any `create`, `update`, `delete`, `make-*`, `refund`, `void` or `use.registers` permission.
- `nexopos.pos.access`.

**Leaks and gaps for a read-only visitor:**
- `POST api/reports/compute/{type}` and `POST api/reports/compute-combined-report` *write* (recompute) but only require `nexopos.reports.sales` (routes/api/reports.php:14, :20).
- The Z-report page has no permission check (routes/web/cash-registers.php:10, CashRegistersController.php:297).
- The web report pages have no permission check; the data APIs do (routes/web/reports.php:6-15).
- `CustomerRewardCrud` has `update => true` (CustomerRewardCrud.php:58-63). `PermissionAccessCrud` has `delete => true` (PermissionAccessCrud.php:55-58).

**Pages that need a write permission just to view:**
- Product detail/edit needs `nexopos.update.products` (ProductsController.php:333-335).
- Procurement edit needs `nexopos.update.procurements` (ProcurementController.php:247-249). Read-only users can still open the invoice with `read.procurements` (:262-264).
- Every CRUD edit form needs `update` (CrudService.php:1446-1455, :1483-1487).
- POS needs `nexopos.pos.access` (routes/web/orders.php:18).
- Settings needs `manage.options` (routes/web/settings.php:7-9).

---

## 9. Other things a simulator must know

**Options to set** (`ns()->option->set`):
- `ns_currency_symbol`, `ns_currency_iso`, and `ns_currency_precision` (**default 0**, AppServiceProvider.php:168; used by `getRaw` and comparisons such as CRS:65);
- `ns_currency_position`, `ns_currency_decimal_separator`, `ns_currency_thousand_separator`;
- `ns_store_name`;
- `ns_datetime_timezone`, `ns_date_format`, `ns_datetime_format` (DateService.php:65-80);
- `ns_pos_vat` (`disabled|flat_vat|variable_vat|products_vat`, app/Settings/pos/vat.php:10-17), `ns_pos_tax_type`, `ns_pos_tax_group`;
- `ns_pos_registers_enabled='yes'` (needed to log payments in registers), `ns_pos_registers_default_change_payment_type`;
- `ns_orders_allow_partial`, `ns_orders_allow_incomplete`;
- `ns_pos_order_types` (POS UI only; the service does not validate the type, DemoCoreService.php:116-119).
- Also required: the default payment types (SetupService.php:263-289) and the accounting chart and rules, `TransactionService::createDefaultAccounts()` (TransactionService.php:1258, :1441-1452). If no rule exists for an event, the journal post silently returns null (AccountingJournalService.php:55-62).

**Events and hooks:**
- Orders: `OrderAfterCheckPerformedEvent` (OS:172, can veto), `OrderAfterCreatedEvent`/`OrderAfterUpdatedEvent`, `OrderAfterPaymentStatusChangedEvent`, `OrderPaymentAfterCreatedEvent`, `OrderProductAfterComputedEvent`, `OrderAfterProductStockCheckedEvent`.
- Procurements: `ProcurementBeforeCreateEvent` (rejects grouped products), `ProcurementAfterSaveProductEvent`, `ProcurementAfterCreateEvent`, `ProcurementBeforeHandledEvent`/`ProcurementAfterHandledEvent`.
- Stock: `ProductAfterStockAdjustmentEvent`, `ProductHistoryAfterCreatedEvent`.
- Filters via `App\Classes\Hook`:
  - `ns-order-attributes` persists extra order columns (OS:1634-1641);
  - `ns-wipeable-tables` adds module tables to the soft reset (ResetService.php:18);
  - `ns-products-decrease-actions` and `ns-products-increase-actions` (PS:2284-2292).

**Queue and mail:**
- `sync`, so every job above adds latency to each `create()`.
- `UsersService::setUser` sends mail for every new user (UsersService.php:132-146, exceptions are logged). Creating cashiers through it requires the option `ns_registration_role`. Prefer the `User` model with `setUserRole` for bulk work. **UNVERIFIED** whether mail is configured here.

**Performance in bulk backfills (per order, static estimate):**
- Product `Cache::remember('store-{id}',60)` on the file cache (OS:1304), the `findOrFail` unit-quantity query, and one OrderStorage insert per line (OS:1495-1502).
- Each sold line writes ProductHistory, which runs COGS plus combined-history queries (RS:1091-1096) and accounting.
- `computeDayReport()` runs once for the order and **once per TransactionHistory line** (≈10 aggregate queries each, RS:44-64), plus a month recompute per DashboardDay save.
- The Customer global scope loads **all** customer-role user ids on every Customer query (Customer.php:55-65).
- Mitigations:
  - backfill day by day with `setTestNow` and `define`;
  - consider `Event::fakeFor` or temporarily removing the report listeners **only** around the backfill, then rebuild with `ns:report --compute` (**UNVERIFIED** that every downstream table rebuilds; the accounting and register rows would be skipped);
  - batch inside one DB transaction per day.
- `OrderStorage` rows are purged daily by `PurgeOrderStorageJob` (routes/console.php:71).
- Procurement delivery writes one barcode image file per line (PRS:942, :965-971).

**Notifications that can fire during simulation:**
- untracked stock operation (RS:197-210);
- unbalanced accounting journal (AccountingJournalService.php:148-155);
- PLU failure (PS:845-859);
- auto-stocked procurements (PRS:994-1002);
- daily low-stock scan (`DetectLowStockProductsJob`, routes/console.php:81).
- No switch was found to globally disable notifications (**UNVERIFIED**).

**Resetting simulator data:** `php artisan ns:reset --mode=soft` truncates orders, procurements, reports, accounting, customers' coupons and similar tables (ResetService.php:16-80+). It does **not** truncate products. Add your module's tables through `ns-wipeable-tables`.
