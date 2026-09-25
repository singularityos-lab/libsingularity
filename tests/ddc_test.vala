private void test_get_vcp_request() {
    uint8[] packet = Singularity.Ddc.encode_get_vcp(Singularity.Ddc.VCP_BRIGHTNESS);
    uint8[] expected = { 0x51, 0x82, 0x01, 0x10, 0xAC };
    assert(packet.length == expected.length);
    for (int i = 0; i < expected.length; i++) assert(packet[i] == expected[i]);
}

private void test_set_vcp_request() {
    uint8[] packet = Singularity.Ddc.encode_set_vcp(Singularity.Ddc.VCP_BRIGHTNESS, 50);
    uint8[] expected = { 0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A };
    assert(packet.length == expected.length);
    for (int i = 0; i < expected.length; i++) assert(packet[i] == expected[i]);
}

private void test_vcp_reply() {
    uint8[] reply = { 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
    uint16 current, maximum;
    assert(Singularity.Ddc.decode_vcp_reply(reply, 0x10, out current, out maximum));
    assert(current == 50);
    assert(maximum == 100);
}

private void test_vcp_reply_rejects_bad_checksum() {
    uint8[] reply = { 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF3 };
    uint16 current, maximum;
    assert(!Singularity.Ddc.decode_vcp_reply(reply, 0x10, out current, out maximum));
}

private void test_vcp_reply_rejects_unsupported_feature() {
    uint8[] reply = { 0x6E, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF3 };
    uint16 current, maximum;
    assert(!Singularity.Ddc.decode_vcp_reply(reply, 0x10, out current, out maximum));
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/ddc/get-vcp-request", test_get_vcp_request);
    Test.add_func("/ddc/set-vcp-request", test_set_vcp_request);
    Test.add_func("/ddc/vcp-reply", test_vcp_reply);
    Test.add_func("/ddc/vcp-reply-bad-checksum", test_vcp_reply_rejects_bad_checksum);
    Test.add_func("/ddc/vcp-reply-unsupported", test_vcp_reply_rejects_unsupported_feature);
    return Test.run();
}
