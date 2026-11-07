/*
 * SonarQube Flutter Plugin - Enables analysis of Dart and Flutter projects into SonarQube.
 * Copyright © 2020 inside|app (contact@insideapp.fr)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
package fr.insideapp.sonarqube.dart.lang.issues.dartanalyzer;

import com.sonarsource.scanner.engine.sensor.test.fixtures.TestInputFileBuilder;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.sonar.api.batch.fs.InputFile;
import org.sonar.api.batch.fs.TextRange;
import org.sonar.api.batch.sensor.issue.NewIssue;
import org.sonar.api.batch.sensor.issue.NewIssueLocation;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

public class DartAnalyzerReportIssueTest {

    @Test
    public void equals() {
        DartAnalyzerReportIssue issue1 = new DartAnalyzerReportIssue("1", "msg", "/test/path", 20);
        DartAnalyzerReportIssue issue2 = new DartAnalyzerReportIssue("1", "msg", "/test/path", 20);
        DartAnalyzerReportIssue issue3 = new DartAnalyzerReportIssue("1", "msg", "/test/path", 20, 5, 4);
        DartAnalyzerReportIssue issue4 = new DartAnalyzerReportIssue("1", "msg", "/test/path", 20, 5, 4);

        assertThat(issue1).isEqualTo(issue2);
        assertThat(issue3).isEqualTo(issue4);
    }

    @Test
    public void notEqual() {
        DartAnalyzerReportIssue issue1 = new DartAnalyzerReportIssue("1", "msg", "/test/path", 20);
        DartAnalyzerReportIssue issue2 = new DartAnalyzerReportIssue("2", "msg", "/test/path", 20);
        DartAnalyzerReportIssue issue3 = new DartAnalyzerReportIssue("1", "msg", "/test/path", 20, 5, 4);
        DartAnalyzerReportIssue issue4 = new DartAnalyzerReportIssue("2", "msg", "/test/path", 20, 5, 4);

        assertThat(issue1).isNotEqualTo(issue2);
        assertThat(issue3).isNotEqualTo(issue4);
    }

    @Test
    public void validIssueLocationWithoutColumn() {
        DartAnalyzerReportIssue issue = new DartAnalyzerReportIssue("1", "msg", "/test/path", 1);
        issueLocationFor(issue, testFile());
    }

    @Test
    public void validTestFile() throws IOException {
        InputFile inputFile = testFile();

        assertThat(inputFile.contents()).hasLineCount(5);
        assertThat(inputFile.contents().split("\\R")[0]).hasSize(19);
        assertThat(inputFile.newRange(1, 0, 1, 19)).isNotNull();
        assertThat(inputFile.newRange(1, 0, 1, 1)).isNotNull();
        assertThat(inputFile.newRange(1, 10, 1, 19)).isNotNull();

        try {
            // the endLineOffset is too long
            inputFile.newRange(1, 0, 1, 20);
            fail("Did not throw exception!");
        } catch (IllegalArgumentException e) {
            // success
        }
    }

    @Test
    public void validIssueLocationWithColumnMaxLength() throws IOException {
        DartAnalyzerReportIssue issue = new DartAnalyzerReportIssue("1", "msg", "/test/path", 1, 10, 10);
        InputFile inputFile = testFile();
        TextRange textRange = textRangeFor(issue, inputFile);

        assertThat(textRange.start().lineOffset()).isEqualTo(9);
        assertThat(textRange.end().lineOffset()).isEqualTo(19);
    }

    @Test
    public void validIssueLocationWithColumnFullLine() {
        DartAnalyzerReportIssue issue = new DartAnalyzerReportIssue("1", "msg", "/test/path", 1, 1, 19);
        TextRange textRange = textRangeFor(issue, testFile());

        assertThat(textRange.start().lineOffset()).isZero();
        assertThat(textRange.end().lineOffset()).isEqualTo(19);
    }

    @Test
    public void validIssueLocationWithColumnLengthOne() {
        DartAnalyzerReportIssue issue = new DartAnalyzerReportIssue("1", "msg", "/test/path", 1, 10, 1);
        TextRange textRange = textRangeFor(issue, testFile());
        assertThat(textRange.start().lineOffset()).isEqualTo(9);
        assertThat(textRange.end().lineOffset()).isEqualTo(10);
    }

    @Test
    public void validIssueLocationWithColumnButNoLength() {
        DartAnalyzerReportIssue issue = new DartAnalyzerReportIssue("1", "msg", "/test/path", 1, 10, null);
        TextRange textRange = textRangeFor(issue, testFile());
        assertThat(textRange.start().lineOffset()).isEqualTo(9);
        assertThat(textRange.end().lineOffset()).isEqualTo(19);
    }

    private TextRange textRangeFor(DartAnalyzerReportIssue issue, InputFile inputFile) {
        NewIssueLocation location = issueLocationFor(issue, inputFile);
        ArgumentCaptor<TextRange> rangeCaptor = ArgumentCaptor.forClass(TextRange.class);
        verify(location).at(rangeCaptor.capture());
        return rangeCaptor.getValue();
    }

    private NewIssueLocation issueLocationFor(DartAnalyzerReportIssue issue, InputFile inputFile) {
        NewIssue newIssue = mock(NewIssue.class);
        NewIssueLocation location = mock(NewIssueLocation.class);
        when(newIssue.newLocation()).thenReturn(location);
        when(location.on(inputFile)).thenReturn(location);
        when(location.message(issue.getMessage())).thenReturn(location);

        NewIssueLocation result = issue.toNewIssueLocationFor(newIssue, inputFile);

        assertThat(result).isSameAs(location);
        verify(newIssue).newLocation();
        verify(location).on(inputFile);
        verify(location).message(issue.getMessage());
        return location;
    }

    private InputFile testFile() {
        // first line has a length of 19
        String content = "import 'dart:core';\n\nmain() {\n  print('test');\n}";
        return new TestInputFileBuilder("test", "test.dart")
                .setContents(content)
                .setCharset(StandardCharsets.UTF_8)
                .build();
    }
}
