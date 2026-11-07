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

import org.junit.Test;
import org.sonar.api.batch.sensor.SensorDescriptor;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

public class DartSensorTest {

    @Test
    public void describe() {
        DartSensor sensor = new DartSensor();
        SensorDescriptor descriptor = mock(SensorDescriptor.class);
        when(descriptor.onlyOnLanguage(Dart.KEY)).thenReturn(descriptor);
        when(descriptor.name("Dart sensor")).thenReturn(descriptor);
        sensor.describe(descriptor);
        verify(descriptor).name("Dart sensor");
    }

}
