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

import org.sonar.api.batch.fs.FileSystem;
import org.sonar.api.batch.fs.InputFile;

import java.io.File;
import java.io.IOException;
import java.nio.file.Path;
import java.util.Optional;

public final class InputFileResolver {
    private InputFileResolver() {
    }

    public static Optional<InputFile> resolve(FileSystem fileSystem, String reportedPath) {
        File resolvedFile = fileSystem.resolvePath(reportedPath);
        InputFile exactMatch = fileSystem.inputFile(
                fileSystem.predicates().hasAbsolutePath(resolvedFile.getAbsolutePath()));

        if (exactMatch != null) {
            return Optional.of(exactMatch);
        }

        try {
            Path canonicalPath = resolvedFile.toPath().toRealPath();
            Path canonicalBaseDirectory = fileSystem.baseDir().toPath().toRealPath();

            if (canonicalPath.startsWith(canonicalBaseDirectory)) {
                String relativePath = canonicalBaseDirectory.relativize(canonicalPath)
                        .toString()
                        .replace(File.separatorChar, '/');
                InputFile relativeMatch = fileSystem.inputFile(
                        fileSystem.predicates().hasRelativePath(relativePath));

                if (relativeMatch != null) {
                    return Optional.of(relativeMatch);
                }
            }

            for (InputFile inputFile : fileSystem.inputFiles(fileSystem.predicates().all())) {
                if (inputFile.path().toRealPath().equals(canonicalPath)) {
                    return Optional.of(inputFile);
                }
            }
        } catch (IOException ignored) {
            // SonarQube can only index existing files, so an unresolved path cannot match an input file.
        }

        return Optional.empty();
    }
}
