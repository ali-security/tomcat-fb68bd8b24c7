/*
 *  Licensed to the Apache Software Foundation (ASF) under one or more
 *  contributor license agreements.  See the NOTICE file distributed with
 *  this work for additional information regarding copyright ownership.
 *  The ASF licenses this file to You under the Apache License, Version 2.0
 *  (the "License"); you may not use this file except in compliance with
 *  the License.  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */
package org.apache.coyote.http2;

import java.io.IOException;
import java.net.SocketTimeoutException;

import org.junit.Assert;
import org.junit.Test;

public class TestHttp2Section_3_5 extends Http2TestBase {

    @Test
    public void testNoConnectionPreface() throws Exception {
        enableHttp2();
        configureAndStartWebApplication();
        openClientConnection();
        doHttpUpgrade();

        // Server settings
        parser.readFrame();
        Assert.assertEquals("0-Settings-[3]-[200]\n" + "0-Settings-End\n", output.getTrace());
        output.clearTrace();

        // Should send client preface here. This will trigger an error.
        // Send two pings (2*(9+8)=34 bytes) as server looks for entire preface
        // of 24 bytes.
        sendPing();
        // Depending on timing, this ping may fail after the header has been
        // sent but before the ping body since:
        // 9 (ping 1 header) + 8 (ping 1 body) + 9 (ping 2 header) = 26 which
        // which is enough data for the server to determine that the preface is
        // invalid and close the connection. A subsequent attempt to send ping 2
        // body will fail.
        try {
            sendPing();
        } catch (IOException e) {
            // Ignore
        }

        // If the client preface had been valid, this would be an
        // acknowledgement. Of the settings. As the preface was invalid, it
        // should be a GOAWAY frame.
        try {
            parser.readFrame();
            Assert.assertTrue(output.getTrace(), output.getTrace().startsWith("0-Goaway-[1]-[1]-["));
        } catch (IOException ioe) {
            // Ignore
            // This is expected on some platforms and depends on timing. Once
            // the server closes the connection the client may see an exception
            // when trying to read the GOAWAY frame.
        }
    }


    @Test
    public void testConnectionPrefaceFollowedByOversizedNonSettingsFrame() throws Exception {
        enableHttp2();
        configureAndStartWebApplication();
        // Don't auto-acknowledge the server settings else the acknowledgement will be sent before the client preface
        openClientConnection();
        doHttpUpgrade();

        /*
         * Valid client preface start but followed by a frame that is not a SETTINGS frame (a stream error) and is
         * larger than the maximum frame size (a connection error). The connection error must take priority.
         * Previously, the stream error masked the connection error and the server attempted to read a payload that
         * could never fit in the buffer provided, entering an endless read loop.
         */
        int payloadSize = ConnectionSettingsBase.DEFAULT_MAX_FRAME_SIZE + 1;
        byte[] frameHeader = new byte[9];
        // Length
        ByteUtil.setThreeBytes(frameHeader, 0, payloadSize);
        // Type
        frameHeader[3] = FrameType.PING.getIdByte();
        // No flags
        // Stream 0

        os.write(Http2Parser.CLIENT_PREFACE_START);
        os.write(frameHeader);
        // Send enough of the payload to completely fill the buffer the server uses to read the payload
        os.write(new byte[ConnectionSettingsBase.DEFAULT_MAX_FRAME_SIZE]);
        os.flush();

        // Server settings
        parser.readFrame();
        Assert.assertEquals("0-Settings-[3]-[200]\n" + "0-Settings-End\n", output.getTrace());
        output.clearTrace();

        if (useAsyncIO) {
            // The connection error is reported via a GOAWAY frame
            handleGoAwayResponse(1);
            // The error must be triggered by the frame size, not the frame type
            Assert.assertTrue(output.getTrace(), output.getTrace().contains("[" + payloadSize + "]"));
        } else {
            // The server closes the connection. It must not wait for the remainder of the oversized payload.
            try {
                parser.readFrame();
                Assert.assertTrue(output.getTrace(), output.getTrace().startsWith("0-Goaway-[1]-["));
            } catch (SocketTimeoutException ste) {
                Assert.fail("Server did not close the connection after receiving an oversized frame");
            } catch (IOException ioe) {
                // Expected. The server closed the connection.
            }
        }
    }
}
