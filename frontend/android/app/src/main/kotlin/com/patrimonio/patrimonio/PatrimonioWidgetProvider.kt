package com.patrimonio.patrimonio

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Height (dp) at or above which the roomy two-line layout is used. One grid
 * row is ~40-70dp depending on device; the tall layout needs ~90dp before its
 * 22sp figure and two sub-lines stop feeling cramped.
 */
private const val TALL_LAYOUT_MIN_HEIGHT_DP = 90

/**
 * Home-screen widget: net worth, USD/MXN, and a sync affordance.
 *
 * ## This provider never touches the network
 *
 * It renders strings the Flutter app already computed and stored (see
 * `utils/home_widget_snapshot.dart`). That is a deliberate architectural
 * choice, not a shortcut:
 *
 *  - the API requires a session cookie held in Keystore-backed secure storage,
 *    and a widget process reading that credential widens where it lives;
 *  - the backend URL is user-configured at runtime (self-hosted), and may need
 *    Cloudflare Access headers — a second copy of that whole seam;
 *  - periodic refresh means WorkManager, which already caused a launch crash
 *    here once (R8 stripped Room's generated `WorkDatabase_Impl` no-arg
 *    constructor; see `proguard-rules.pro`).
 *
 * So the widget is app-pushed: it shows the last values the app saw, and the
 * freshness line says how old they are. Tapping it opens the app, which
 * refreshes and re-pushes.
 *
 * ## Formatting
 *
 * Every value arrives preformatted. RemoteViews cannot reach the reporting
 * currency, the active locale, or `utils/currency.dart`, so formatting here
 * would be a fourth money formatter guaranteed to drift from the app.
 */
open class PatrimonioWidgetProvider : AppWidgetProvider() {

    /**
     * Resizing does NOT trigger onUpdate — without this override the widget
     * keeps whichever layout it was first drawn with, so dragging it taller
     * would leave the cramped single-row version in a two-row cell.
     */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        onUpdate(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    /** Roomy layout only once the host actually gives us the height for it. */
    private fun layoutFor(appWidgetManager: AppWidgetManager, id: Int): Int {
        val height = appWidgetManager
            .getAppWidgetOptions(id)
            .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        return if (height >= TALL_LAYOUT_MIN_HEIGHT_DP) {
            R.layout.patrimonio_widget
        } else {
            R.layout.patrimonio_widget_compact
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            // home_widget persists into this SharedPreferences instance; read
            // it directly rather than re-deriving the file name, so a plugin
            // upgrade that moves the store can't silently strand us on stale
            // values.
            val prefs = HomeWidgetPlugin.getData(context)
            val layoutId = layoutFor(appWidgetManager, id)
            val compact = layoutId == R.layout.patrimonio_widget_compact
            val views = RemoteViews(context.packageName, layoutId)

            // Absent keys mean the app has never pushed (widget placed before
            // first launch). Default the toggles ON to match Settings, and
            // leave the values blank rather than inventing a zero — a widget
            // claiming "$0" would be a lie about someone's net worth.
            val showNetWorth = prefs.getString("show_net_worth", "true") != "false"
            val showFx = prefs.getString("show_fx", "true") != "false"
            val showSync = prefs.getString("show_sync", "true") != "false"
            val allHidden = !showNetWorth && !showFx && !showSync

            val netWorth = prefs.getString("net_worth", "").orEmpty()
            val fxRate = prefs.getString("fx_rate", "").orEmpty()
            val syncedAt = prefs.getString("synced_at", "").orEmpty()
            // Compact shares one line between the rate and the age, so it uses
            // the ultra-short age ("2h", "now"); the full "2h ago" ellipsed to
            // "· j…" at two columns. Both forms are built in Dart — see
            // HomeWidgetSnapshot.syncedAtShort.
            val syncedAtShort = prefs.getString("synced_at_short", "")
                .orEmpty()
                .ifEmpty { syncedAt }

            val showFxRow = showFx && !allHidden && fxRate.isNotEmpty()

            // The toggles form six layouts, and each must look DESIGNED, not
            // like a layout with holes. The rule: the hero slot is never left
            // empty while there is something to promote into it. With net
            // worth hidden, the RATE takes the hero slot (autosized, accent
            // colour) — a widget the user configured down to "just FX" should
            // read as a purpose-built rate tile, not as a net-worth tile with
            // the number knocked out (which shipped: a floating sync icon
            // above a small rate line in a mostly-empty card).
            val fxHero = showFxRow && !showNetWorth

            views.setViewVisibility(
                R.id.widget_net_worth,
                if ((showNetWorth || fxHero) && !allHidden) View.VISIBLE else View.GONE,
            )
            views.setViewVisibility(
                R.id.widget_sync,
                if (showSync && !allHidden) View.VISIBLE else View.GONE,
            )
            // The FX row hides when switched off, when there is no rate yet —
            // an empty accent-coloured line reads as a rendering bug — and
            // when the rate was promoted to the hero slot.
            views.setViewVisibility(
                R.id.widget_fx,
                if (showFxRow && !fxHero) View.VISIBLE else View.GONE,
            )
            // Compact has no room for a dedicated age line, so the age rides
            // on the rate line instead — and only needs its own row when
            // there is no rate line to ride on (including when the rate is
            // the hero, whose slot carries no age). Dropping it entirely was
            // not an option: these values are only as fresh as the last app
            // launch, and an unlabelled stale number reads as a live one.
            val ageOnItsOwnLine = if (compact) (!showFxRow || fxHero) else true
            views.setViewVisibility(
                R.id.widget_synced_at,
                if (!allHidden && syncedAt.isNotEmpty() && ageOnItsOwnLine) {
                    View.VISIBLE
                } else {
                    View.GONE
                },
            )
            views.setViewVisibility(
                R.id.widget_empty,
                if (allHidden) View.VISIBLE else View.GONE,
            )

            if (fxHero) {
                views.setTextViewText(R.id.widget_net_worth, "USD/MXN $fxRate")
                views.setTextColor(
                    R.id.widget_net_worth,
                    context.getColor(R.color.widget_accent),
                )
                views.setContentDescription(
                    R.id.widget_net_worth,
                    context.getString(R.string.widget_rate_label),
                )
            } else {
                views.setTextViewText(R.id.widget_net_worth, netWorth)
                // Explicitly restore: RemoteViews are rebuilt each update, but
                // being explicit keeps the two branches symmetric.
                views.setTextColor(
                    R.id.widget_net_worth,
                    context.getColor(R.color.widget_text_primary),
                )
                views.setContentDescription(
                    R.id.widget_net_worth,
                    context.getString(R.string.widget_net_worth_label),
                )
            }
            // The pair label is chrome, not data — it belongs next to the
            // number, and keeping it here spares Dart from re-sending a
            // constant on every push.
            val fxText = if (compact && syncedAtShort.isNotEmpty()) {
                "USD/MXN $fxRate · $syncedAtShort"
            } else {
                "USD/MXN $fxRate"
            }
            views.setTextViewText(R.id.widget_fx, fxText)
            views.setTextViewText(R.id.widget_synced_at, syncedAt)

            // The net-worth trend bitmap the app rendered ('chart_path' is a
            // file path from renderFlutterWidget). Follows the net-worth
            // toggle — it IS net-worth data — and hides on any problem
            // (no push yet, deleted file, decode failure): a missing chart
            // is a tighter card, a broken one is a support ticket.
            val chartPath = prefs.getString("chart_path", "").orEmpty()
            val chart = if (showNetWorth && !allHidden && chartPath.isNotEmpty()) {
                runCatching { BitmapFactory.decodeFile(chartPath) }.getOrNull()
            } else {
                null
            }
            if (chart != null) {
                views.setImageViewBitmap(R.id.widget_chart, chart)
                views.setViewVisibility(R.id.widget_chart, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_chart, View.GONE)
            }

            // Two DIFFERENT taps. The sync glyph carries a `patrimonio://sync`
            // URI that the Flutter side reads on launch and turns into a real
            // sync-everything run (see dashboard_screen's widget-launch hook) —
            // "just opens the app" was not what a button labelled sync should
            // do. The rest of the tile is a plain launch.
            //
            // HomeWidgetLaunchIntent is the plugin's supported delivery path
            // for that URI; it builds the immutable PendingIntent for us.
            views.setOnClickPendingIntent(
                R.id.widget_sync,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("patrimonio://sync"),
                ),
            )
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP }
            if (launch != null) {
                val pending = PendingIntent.getActivity(
                    context,
                    0,
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(R.id.widget_net_worth, pending)
                views.setOnClickPendingIntent(R.id.widget_empty, pending)
            }

            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
