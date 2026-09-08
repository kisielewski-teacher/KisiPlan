package com.example.kisiplan

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Shows the current/next lesson on the Android home screen. Data is written
 * from Dart via WidgetService (lib/services/widget_service.dart) through the
 * home_widget plugin's SharedPreferences bridge.
 */
class TimetableWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.timetable_widget_layout)

            views.setTextViewText(
                R.id.widget_status,
                widgetData.getString("status", "Plan Mechanika"),
            )
            views.setTextViewText(
                R.id.widget_subject,
                widgetData.getString("subject", "Brak lekcji"),
            )
            setRowText(views, R.id.widget_time, widgetData.getString("time", ""))
            setRowText(views, R.id.widget_room, widgetData.getString("room", ""))
            setRowText(views, R.id.widget_class, widgetData.getString("className", ""))

            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    /** Sets a row's text, collapsing it entirely (freeing its layout_weight
     *  to the rows still visible) when there's nothing to show. */
    private fun setRowText(views: RemoteViews, viewId: Int, text: String?) {
        if (text.isNullOrEmpty()) {
            views.setViewVisibility(viewId, View.GONE)
        } else {
            views.setViewVisibility(viewId, View.VISIBLE)
            views.setTextViewText(viewId, text)
        }
    }
}
