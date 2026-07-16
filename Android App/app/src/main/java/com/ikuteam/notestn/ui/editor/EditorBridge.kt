package com.ikuteam.notestn.ui.editor

import kotlinx.serialization.Serializable

/** Mirrors the JS `SelectionState` interface in Mac/EditorBundle/src/index.ts. */
@Serializable
data class EditorSelectionState(
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
    val strikethrough: Boolean = false,
    val highlight: Boolean = false,
    val inCode: Boolean = false,
    val inBlockquote: Boolean = false,
    val inBulletList: Boolean = false,
    val inOrderedList: Boolean = false,
    val inTaskList: Boolean = false,
    val inCheckedTask: Boolean = false,
    val headingLevel: Int = 0,
    val hasLink: Boolean = false,
    val linkHref: String? = null,
)

/** Mirrors the JS `NativeMessage` interface (JS → native) in the same file. */
@Serializable
data class EditorBridgeMessage(
    val type: String,
    val title: String? = null,
    val html: String? = null,
    val selectionState: EditorSelectionState? = null,
    val message: String? = null,
    val url: String? = null,
    val focused: Boolean? = null,
)
