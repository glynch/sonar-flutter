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
package fr.insideapp.sonarqube.dart.lang;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.sonar.api.batch.fs.FilePredicate;
import org.sonar.api.batch.fs.FilePredicates;
import org.sonar.api.batch.fs.FileSystem;
import org.sonar.api.batch.fs.InputFile;

import java.io.File;
import java.io.IOException;
import java.util.Collections;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

public class InputFileResolverTest {
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void resolvesAnExactAbsolutePath() {
        FileSystem fileSystem = mock(FileSystem.class);
        FilePredicates predicates = mock(FilePredicates.class);
        FilePredicate absolutePathPredicate = mock(FilePredicate.class);
        InputFile inputFile = mock(InputFile.class);
        File sourceFile = new File("source.dart").getAbsoluteFile();

        when(fileSystem.resolvePath(sourceFile.getPath())).thenReturn(sourceFile);
        when(fileSystem.predicates()).thenReturn(predicates);
        when(predicates.hasAbsolutePath(sourceFile.getPath())).thenReturn(absolutePathPredicate);
        when(fileSystem.inputFile(absolutePathPredicate)).thenReturn(inputFile);

        assertThat(InputFileResolver.resolve(fileSystem, sourceFile.getPath()))
                .contains(inputFile);
    }

    @Test
    public void resolvesACanonicalEquivalentPath() throws IOException {
        File baseDirectory = temporaryFolder.newFolder("project");
        File sourceDirectory = new File(baseDirectory, "lib");
        assertThat(sourceDirectory.mkdir()).isTrue();
        File sourceFile = new File(sourceDirectory, "source.dart");
        assertThat(sourceFile.createNewFile()).isTrue();
        File aliasedSourceFile = new File(sourceDirectory, "../lib/source.dart");

        FileSystem fileSystem = mock(FileSystem.class);
        FilePredicates predicates = mock(FilePredicates.class);
        FilePredicate absolutePathPredicate = mock(FilePredicate.class);
        FilePredicate relativePathPredicate = mock(FilePredicate.class);
        InputFile inputFile = mock(InputFile.class);

        when(fileSystem.resolvePath(aliasedSourceFile.getPath())).thenReturn(aliasedSourceFile);
        when(fileSystem.baseDir()).thenReturn(baseDirectory);
        when(fileSystem.predicates()).thenReturn(predicates);
        when(predicates.hasAbsolutePath(aliasedSourceFile.getAbsolutePath())).thenReturn(absolutePathPredicate);
        when(fileSystem.inputFile(absolutePathPredicate)).thenReturn(null);
        when(predicates.hasRelativePath("lib/source.dart")).thenReturn(relativePathPredicate);
        when(fileSystem.inputFile(relativePathPredicate)).thenReturn(inputFile);

        assertThat(InputFileResolver.resolve(fileSystem, aliasedSourceFile.getPath()))
                .contains(inputFile);
    }

    @Test
    public void resolvesCanonicalEquivalentPathOutsideTheBaseDirectory() throws IOException {
        File baseDirectory = temporaryFolder.newFolder("project");
        File sourceFile = temporaryFolder.newFile("source.dart");
        InputFile inputFile = mock(InputFile.class);

        FileSystem fileSystem = mock(FileSystem.class);
        FilePredicates predicates = mock(FilePredicates.class);
        FilePredicate absolutePathPredicate = mock(FilePredicate.class);
        FilePredicate allFilesPredicate = mock(FilePredicate.class);

        when(fileSystem.resolvePath(sourceFile.getPath())).thenReturn(sourceFile);
        when(fileSystem.baseDir()).thenReturn(baseDirectory);
        when(fileSystem.predicates()).thenReturn(predicates);
        when(predicates.hasAbsolutePath(sourceFile.getAbsolutePath())).thenReturn(absolutePathPredicate);
        when(fileSystem.inputFile(absolutePathPredicate)).thenReturn(null);
        when(predicates.all()).thenReturn(allFilesPredicate);
        when(fileSystem.inputFiles(allFilesPredicate)).thenReturn(Collections.singletonList(inputFile));
        when(inputFile.path()).thenReturn(new File(sourceFile.getParentFile(), "./source.dart").toPath());

        assertThat(InputFileResolver.resolve(fileSystem, sourceFile.getPath()))
                .contains(inputFile);
    }
}
