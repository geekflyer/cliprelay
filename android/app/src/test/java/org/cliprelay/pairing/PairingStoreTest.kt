package org.cliprelay.pairing

import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for PairingStore multi-Mac storage, identity tag, migration,
 * and rich media settings.
 * Uses an in-memory SharedPreferences fake so no Android context is needed.
 */
class PairingStoreTest {

    private lateinit var store: PairingStore

    private val secretA = "aa".repeat(32)
    private val secretB = "bb".repeat(32)

    @Before
    fun setUp() {
        store = PairingStore(FakeSharedPreferences())
    }

    @Test
    fun `richMediaEnabled defaults to false`() {
        assertFalse(store.isRichMediaEnabled())
    }

    @Test
    fun `richMediaEnabledChangedAt defaults to zero`() {
        assertEquals(0L, store.getRichMediaEnabledChangedAt())
    }

    @Test
    fun `save and load richMediaEnabled true`() {
        val now = System.currentTimeMillis() / 1000
        store.setRichMediaEnabled(true, now)
        assertTrue(store.isRichMediaEnabled())
        assertEquals(now, store.getRichMediaEnabledChangedAt())
    }

    @Test
    fun `save and load richMediaEnabled false`() {
        val now = System.currentTimeMillis() / 1000
        store.setRichMediaEnabled(true, now)
        val later = now + 10
        store.setRichMediaEnabled(false, later)
        assertFalse(store.isRichMediaEnabled())
        assertEquals(later, store.getRichMediaEnabledChangedAt())
    }

    @Test
    fun `clear resets richMediaEnabled`() {
        val now = System.currentTimeMillis() / 1000
        store.setRichMediaEnabled(true, now)
        store.clear()
        assertFalse(store.isRichMediaEnabled())
        assertEquals(0L, store.getRichMediaEnabledChangedAt())
    }

    @Test
    fun `clear also resets paired macs and identity tag`() {
        store.addPairedMac(secretA, "Mac A")
        store.clear()
        assertTrue(store.loadPairedMacs().isEmpty())
        assertNull(store.identityTagHex())
    }

    @Test
    fun `paired mac round-trip`() {
        assertTrue(store.addPairedMac(secretA, "Mac A", pairedAtMs = 42L))
        val macs = store.loadPairedMacs()
        assertEquals(1, macs.size)
        assertEquals(secretA, macs[0].secretHex)
        assertEquals("Mac A", macs[0].name)
        assertEquals(42L, macs[0].pairedAtMs)
    }

    @Test
    fun `first pairing sets identity tag from secret`() {
        store.addPairedMac(secretA, "Mac A")
        val expected = org.cliprelay.crypto.E2ECrypto.deviceTag(secretA)
            .joinToString("") { "%02x".format(it) }
        assertEquals(expected, store.identityTagHex())
    }

    @Test
    fun `second pairing keeps the original identity tag`() {
        store.addPairedMac(secretA, "Mac A")
        val tag = store.identityTagHex()
        store.addPairedMac(secretB, "Mac B")
        assertEquals(tag, store.identityTagHex())
        assertEquals(2, store.loadPairedMacs().size)
    }

    @Test
    fun `identity tag survives removal of the first mac while others remain`() {
        store.addPairedMac(secretA, "Mac A")
        val tag = store.identityTagHex()
        store.addPairedMac(secretB, "Mac B")
        store.removePairedMac(secretA)
        assertEquals(tag, store.identityTagHex())
        assertEquals(listOf(secretB), store.loadPairedMacs().map { it.secretHex })
    }

    @Test
    fun `removing the last mac clears the identity tag`() {
        store.addPairedMac(secretA, "Mac A")
        store.removePairedMac(secretA)
        assertTrue(store.loadPairedMacs().isEmpty())
        assertNull(store.identityTagHex())
    }

    @Test
    fun `re-adding the same secret replaces instead of duplicating`() {
        store.addPairedMac(secretA, "Old Name")
        store.addPairedMac(secretA, "New Name")
        val macs = store.loadPairedMacs()
        assertEquals(1, macs.size)
        assertEquals("New Name", macs[0].name)
    }

    @Test
    fun `addPairedMac enforces the limit`() {
        repeat(PairingStore.MAX_PAIRED_MACS) { i ->
            assertTrue(store.addPairedMac("%02x".format(i + 1).repeat(32), "Mac $i"))
        }
        assertFalse(store.addPairedMac("ff".repeat(32), "One Too Many"))
        assertEquals(PairingStore.MAX_PAIRED_MACS, store.loadPairedMacs().size)
    }

    @Test
    fun `updateMacName renames an existing pairing`() {
        store.addPairedMac(secretA, null)
        store.updateMacName(secretA, "Christian's Mac")
        assertEquals("Christian's Mac", store.loadPairedMacs()[0].name)
    }

    @Test
    fun `legacy single secret migrates to paired macs list with identity tag`() {
        val legacyPrefs = FakeSharedPreferences()
        legacyPrefs.edit().putString(PairingStore.KEY_SHARED_SECRET, secretA).apply()
        val migrated = PairingStore(legacyPrefs)
        assertEquals(listOf(secretA), migrated.loadPairedMacs().map { it.secretHex })
        val expectedTag = org.cliprelay.crypto.E2ECrypto.deviceTag(secretA)
            .joinToString("") { "%02x".format(it) }
        assertEquals(expectedTag, migrated.identityTagHex())
        assertNull(legacyPrefs.getString(PairingStore.KEY_SHARED_SECRET, null))
    }

    @Test
    fun `mac id is stable and derived from secret`() {
        store.addPairedMac(secretA, "Mac A")
        val expected = org.cliprelay.crypto.E2ECrypto.deviceTag(secretA)
            .joinToString("") { "%02x".format(it) }
        assertEquals(expected, store.loadPairedMacs()[0].id)
    }
}

/**
 * Minimal in-memory SharedPreferences implementation for unit tests.
 */
private class FakeSharedPreferences : SharedPreferences {
    private val data = mutableMapOf<String, Any?>()
    private val listeners = mutableSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()

    override fun getAll(): MutableMap<String, *> = HashMap(data)
    override fun getString(key: String, defValue: String?): String? =
        if (data.containsKey(key)) data[key] as? String else defValue
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        @Suppress("UNCHECKED_CAST")
        if (data.containsKey(key)) data[key] as? MutableSet<String> else defValues
    override fun getInt(key: String, defValue: Int): Int =
        if (data.containsKey(key)) data[key] as? Int ?: defValue else defValue
    override fun getLong(key: String, defValue: Long): Long =
        if (data.containsKey(key)) data[key] as? Long ?: defValue else defValue
    override fun getFloat(key: String, defValue: Float): Float =
        if (data.containsKey(key)) data[key] as? Float ?: defValue else defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        if (data.containsKey(key)) data[key] as? Boolean ?: defValue else defValue
    override fun contains(key: String): Boolean = data.containsKey(key)
    override fun edit(): SharedPreferences.Editor = FakeEditor(data, listeners)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.add(listener)
    }
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.remove(listener)
    }
}

private class FakeEditor(
    private val data: MutableMap<String, Any?>,
    private val listeners: Set<SharedPreferences.OnSharedPreferenceChangeListener>
) : SharedPreferences.Editor {
    private val pending = mutableMapOf<String, Any?>()
    private val removals = mutableSetOf<String>()
    private var clearAll = false

    override fun putString(key: String, value: String?): SharedPreferences.Editor {
        pending[key] = value; removals.remove(key); return this
    }
    override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor {
        pending[key] = values; removals.remove(key); return this
    }
    override fun putInt(key: String, value: Int): SharedPreferences.Editor {
        pending[key] = value; removals.remove(key); return this
    }
    override fun putLong(key: String, value: Long): SharedPreferences.Editor {
        pending[key] = value; removals.remove(key); return this
    }
    override fun putFloat(key: String, value: Float): SharedPreferences.Editor {
        pending[key] = value; removals.remove(key); return this
    }
    override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor {
        pending[key] = value; removals.remove(key); return this
    }
    override fun remove(key: String): SharedPreferences.Editor {
        removals.add(key); pending.remove(key); return this
    }
    override fun clear(): SharedPreferences.Editor {
        clearAll = true; return this
    }
    override fun commit(): Boolean {
        applyChanges(); return true
    }
    override fun apply() {
        applyChanges()
    }
    private fun applyChanges() {
        if (clearAll) data.clear()
        removals.forEach { data.remove(it) }
        data.putAll(pending)
    }
}
