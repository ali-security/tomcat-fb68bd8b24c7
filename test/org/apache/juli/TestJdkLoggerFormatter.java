/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.juli;

import java.util.logging.Level;
import java.util.logging.LogRecord;

import org.junit.Assert;
import org.junit.Test;

public class TestJdkLoggerFormatter {

    /*
     * A record with no message is legal. The formatter must render it, with the message as an empty string, rather
     * than throw a NullPointerException.
     */
    @Test
    public void testNullMessage() {
        JdkLoggerFormatter formatter = new JdkLoggerFormatter();
        LogRecord logRecord = new LogRecord(Level.FINE, null);
        logRecord.setLoggerName("test");

        String result = formatter.format(logRecord);

        // With an empty message the line has nothing after the padding of the logger name, in particular the
        // string "null" must not appear in place of the message
        Assert.assertTrue("Unexpected result [" + result + "]",
                result.endsWith(System.lineSeparator()));
        Assert.assertFalse("Unexpected result [" + result + "]", result.contains("null"));
    }


    /*
     * ANSI escape sequences (e.g. from a specially crafted URL) in a log message must not reach the console in a form
     * that the console would interpret.
     */
    @Test
    public void testAnsiEscapeInMessage() {
        JdkLoggerFormatter formatter = new JdkLoggerFormatter();
        LogRecord logRecord =
                new LogRecord(Level.INFO, "Invalid URI [/\u001b[31mred\u001b[0m\u001b]52;c;Y2FsYw==\u0007]");
        logRecord.setLoggerName("test");

        String result = formatter.format(logRecord);

        Assert.assertEquals("Unexpected result [" + result + "]", -1, result.indexOf('\u001b'));
        Assert.assertEquals("Unexpected result [" + result + "]", -1, result.indexOf('\u0007'));
        Assert.assertTrue("Unexpected result [" + result + "]",
                result.endsWith("Invalid URI [/\\u001b[31mred\\u001b[0m\\u001b]52;c;Y2FsYw==\\u0007]" +
                        System.lineSeparator()));
    }


    /*
     * ANSI escape sequences in the message of a logged exception must be escaped in the stack trace too.
     */
    @Test
    public void testAnsiEscapeInStackTrace() {
        JdkLoggerFormatter formatter = new JdkLoggerFormatter();
        LogRecord logRecord = new LogRecord(Level.SEVERE, "Error");
        logRecord.setLoggerName("test");
        logRecord.setThrown(new IllegalArgumentException("Bad \u001b]52;c;Y2FsYw==\u0007 value"));

        String result = formatter.format(logRecord);

        Assert.assertEquals("Unexpected result [" + result + "]", -1, result.indexOf('\u001b'));
        Assert.assertEquals("Unexpected result [" + result + "]", -1, result.indexOf('\u0007'));
        Assert.assertTrue("Unexpected result [" + result + "]",
                result.contains("java.lang.IllegalArgumentException: Bad \\u001b]52;c;Y2FsYw==\\u0007 value"));
        // Tabs and new lines used to format the stack trace are not escaped
        Assert.assertTrue("Unexpected result [" + result + "]", result.contains(System.lineSeparator() + "\tat "));
    }
}
