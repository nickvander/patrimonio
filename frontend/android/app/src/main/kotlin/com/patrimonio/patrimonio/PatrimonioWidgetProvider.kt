package com.patrimonio.patrimonio

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

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
class PatrimonioWidgetProvider : AppWidgetProvider() {

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
            val views = RemoteViews(context.packageName, R.layout.patrimonio_widget)

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

            views.setViewVisibility(
                R.id.widget_net_worth,
                if (showNetWorth && !allHidden) View.VISIBLE else View.GONE,
            )
            views.setViewVisibility(
                R.id.widget_sync,
                if (showSync && !allHidden) View.VISIBLE else View.GONE,
            )
            // The FX row hides both when switched off AND when there is no
            // rate yet — an empty accent-coloured line reads as a rendering
            // bug, where an absent one just reads as a tighter card.
            views.setViewVisibility(
                R.id.widget_fx,
                if (showFx && !allHidden && fxRate.isNotEmpty()) View.VISIBLE else View.GONE,
            )
            views.setViewVisibility(
                R.id.widget_synced_at,
                if (!allHidden && syncedAt.isNotEmpty()) View.VISIBLE else View.GONE,
            )
            views.setViewVisibility(
                R.id.widget_empty,
                if (allHidden) View.VISIBLE else View.GONE,
            )

            views.setTextViewText(R.id.widget_net_worth, netWorth)
            // The pair label is chrome, not data — it belongs next to the
            // number, and keeping it here spares Dart from re-sending a
            // constant on every push.
            views.setTextViewText(R.id.widget_fx, "USD/MXN $fxRate")
            views.setTextViewText(R.id.widget_synced_at, syncedAt)

            // Whole tile and the sync glyph both open the app. FLAG_IMMUTABLE
            // is required from API 31; we never fill in the intent, so an
            // immutable one is also the correct choice on principle.
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
                views.setOnClickPendingIntent(R.id.widget_sync, pending)
                views.setOnClickPendingIntent(R.id.widget_net_worth, pending)
                views.setOnClickPendingIntent(R.id.widget_empty, pending)
            }

            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
