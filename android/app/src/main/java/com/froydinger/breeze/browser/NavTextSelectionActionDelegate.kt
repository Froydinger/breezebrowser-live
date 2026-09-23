package com.froydinger.breeze.browser

import android.app.Activity
import android.view.MenuItem
import org.mozilla.geckoview.BasicSelectionActionDelegate
import org.mozilla.geckoview.GeckoSession

/** Adds explicit Share and Ask Nav callbacks to GeckoView's standard selection toolbar. */
class NavTextSelectionActionDelegate(
    activity: Activity,
    private val onShareText: (selectedText: String) -> Unit,
    private val onAskNav: (selectedText: String) -> Unit,
) : BasicSelectionActionDelegate(activity) {
    private var eligibleSelection = false
    private var allActions: Array<String>? = null

    override fun getAllActions(): Array<String> {
        return allActions ?: (super.getAllActions() + CUSTOM_ACTIONS).also { allActions = it }
    }

    override fun isActionAvailable(id: String): Boolean {
        return when (id) {
            ACTION_SHARE_TEXT, ACTION_ASK_NAV -> eligibleSelection
            else -> super.isActionAvailable(id)
        }
    }

    override fun prepareAction(id: String, item: MenuItem) {
        when (id) {
            ACTION_SHARE_TEXT -> {
                item.title = "Share"
                item.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            }
            ACTION_ASK_NAV -> {
                item.title = "Ask Nav"
                item.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            }
            else -> super.prepareAction(id, item)
        }
    }

    override fun performAction(id: String, item: MenuItem): Boolean {
        val selectedText = selectedTextForAction() ?: return when (id) {
            ACTION_SHARE_TEXT, ACTION_ASK_NAV -> true
            else -> super.performAction(id, item)
        }
        when (id) {
            ACTION_SHARE_TEXT -> onShareText(selectedText)
            ACTION_ASK_NAV -> onAskNav(selectedText)
            else -> return super.performAction(id, item)
        }
        return true
    }

    override fun onShowActionRequest(
        session: GeckoSession,
        selection: GeckoSession.SelectionActionDelegate.Selection,
    ) {
        eligibleSelection = selection.text.isNotBlank() &&
            (selection.flags and GeckoSession.SelectionActionDelegate.FLAG_IS_PASSWORD) == 0
        super.onShowActionRequest(session, selection)
    }

    override fun onHideAction(session: GeckoSession, reason: Int) {
        eligibleSelection = false
        super.onHideAction(session, reason)
    }

    private fun selectedTextForAction(): String? {
        if (!eligibleSelection) return null
        return getSelection()?.text?.takeIf(String::isNotBlank)
    }

    private companion object {
        const val ACTION_SHARE_TEXT = "com.froydinger.breeze.selection_share"
        const val ACTION_ASK_NAV = "com.froydinger.breeze.selection_ask_nav"
        val CUSTOM_ACTIONS = arrayOf(ACTION_SHARE_TEXT, ACTION_ASK_NAV)
    }
}
