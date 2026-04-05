package org.cliprelay.settings

import org.junit.Test
import org.junit.Assert.*

class ClipboardSettingsStoreTest {

    @Test
    fun `auto copy default is false`() {
        assertEquals("auto_copy_enabled", ClipboardSettingsStore.KEY_AUTO_COPY_ENABLED)
    }

    @Test
    fun `onboarding shown key is defined`() {
        assertEquals("auto_copy_onboarding_shown", ClipboardSettingsStore.KEY_AUTO_COPY_ONBOARDING_SHOWN)
    }
}
