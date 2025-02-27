# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import unittest


class TestDaliTfPluginLoadOk(unittest.TestCase):
    def test_import_dali_tf_ok(self):
        import nvidia.dali.plugin.tf as dali_tf
        assert True


class TestDaliTfPluginLoadFail(unittest.TestCase):
    def test_import_dali_tf_load_fail(self):
        with self.assertRaises(Exception):
            import nvidia.dali.plugin.tf as dali_tf


if __name__ == '__main__':
    unittest.main()
