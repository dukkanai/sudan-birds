import json
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import ios_native_storage as smoke

RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-18-0'
TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'
UUID = 'A1234567-1234-1234-1234-123456789ABC'
NAME = 'birds-storage-' + 'a' * 32
STATE = {'name': NAME, 'uuid': UUID, 'runtime': RUNTIME, 'device': TYPE}


def data(state='Shutdown'):
    return {'runtimes': [{'identifier': RUNTIME, 'version': '18.0', 'isAvailable': True}],
            'devicetypes': [{'identifier': TYPE, 'minRuntimeVersion': 18 * 65536,
                             'maxRuntimeVersion': 0xFFFFFFFF}],
            'devices': {RUNTIME: [{'udid': UUID, 'name': NAME, 'deviceTypeIdentifier': TYPE,
                                   'isAvailable': True, 'state': state}]}}


class Guards(unittest.TestCase):
    def setUp(self):
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def test_select_installed_compatible(self):
        self.assertEqual(smoke.select(data()), (RUNTIME, TYPE))

    def test_no_unavailable_old_or_unknown_compatibility(self):
        for mutation in ['unavailable', 'incompatible', 'unknown', 'old', 'not_iphone']:
            item = data()
            if mutation == 'unavailable':
                item['runtimes'][0]['isAvailable'] = False
            elif mutation == 'incompatible':
                item['devicetypes'][0]['minRuntimeVersion'] = 19 * 65536
            elif mutation == 'unknown':
                del item['devicetypes'][0]['maxRuntimeVersion']
            elif mutation == 'old':
                item['runtimes'][0]['version'] = '12.0'
            else:
                item['devicetypes'][0]['identifier'] = TYPE.replace('iPhone', 'iPad')
            with self.subTest(mutation=mutation), self.assertRaises(smoke.Failure):
                smoke.select(item)

    def test_ownership_every_identity_field(self):
        for field in ['name', 'deviceTypeIdentifier', 'isAvailable']:
            item = data()
            item['devices'][RUNTIME][0][field] = 'mismatch'
            with self.subTest(field=field), self.assertRaises(smoke.Failure):
                smoke.owned(item, STATE)
        item = data()
        item['devices']['different'] = item['devices'].pop(RUNTIME)
        with self.assertRaises(smoke.Failure):
            smoke.owned(item, STATE)

    def test_duplicate_uuid_rejected(self):
        item = data()
        item['devices'][RUNTIME] *= 2
        with self.assertRaises(smoke.Failure):
            smoke.owned(item, STATE)

    def test_cleanup_exact_uuid_and_verified_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'owned.json', STATE)
            with patch.object(smoke, 'inventory', side_effect=[data('Booted'), data(), {'devices': {}}]), patch.object(smoke, 'run') as run:
                smoke.cleanup(path)
            self.assertEqual([c.args[0] for c in run.call_args_list], [
                ['xcrun', 'simctl', 'shutdown', UUID], ['xcrun', 'simctl', 'delete', UUID]])
            self.assertTrue(all(c.kwargs['seconds'] == 30 for c in run.call_args_list))

    def test_cleanup_refuses_mismatch_and_uncertain_state(self):
        for state in ['Booting', 'Shutting Down', 'Creating']:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                smoke.save(path / 'owned.json', STATE)
                with patch.object(smoke, 'inventory', return_value=data(state)), patch.object(smoke, 'run') as run:
                    with self.assertRaises(smoke.Failure):
                        smoke.cleanup(path)
                    run.assert_not_called()

    def test_failed_shutdown_prevents_delete(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'owned.json', STATE)
            with patch.object(smoke, 'inventory', return_value=data('Booted')), patch.object(smoke, 'run', side_effect=smoke.Failure('failed')) as run:
                with self.assertRaises(smoke.Failure):
                    smoke.cleanup(path)
                self.assertEqual(run.call_count, 1)

    def test_uncertain_create_never_adopted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'creation-attempted').touch()
            with patch.object(smoke, 'run') as run:
                with self.assertRaises(smoke.Failure):
                    smoke.cleanup(path)
                run.assert_not_called()

    def test_absent_is_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'owned.json', STATE)
            with patch.object(smoke, 'inventory', return_value={'devices': {}}), patch.object(smoke, 'run') as run:
                smoke.cleanup(path)
                run.assert_not_called()

    def test_symlink_record_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'real.json', STATE)
            (path / 'owned.json').symlink_to(path / 'real.json')
            with self.assertRaises(smoke.Failure):
                smoke.load(path / 'owned.json')

    def test_reused_directory_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'owned.json', STATE)
            with patch.object(smoke, 'inventory') as inventory:
                with self.assertRaises(smoke.Failure):
                    smoke.execute(path)
                inventory.assert_not_called()

    def test_execute_exact_target_and_device(self):
        before = data()
        before['devices'] = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            fake_uuid = type('FakeUUID', (), {'hex': 'a' * 32})()
            with patch.object(smoke.uuid, 'uuid4', return_value=fake_uuid), patch.object(smoke, 'inventory', side_effect=[before, data(), data(), data('Booted')]) as inventory, patch.object(smoke, 'run') as run:
                smoke.execute(path)
            self.assertEqual([call.kwargs for call in inventory.call_args_list],
                             [{'cold': True, 'stage': 'inventory-initial'},
                              {'stage': 'inventory-created'},
                              {'stage': 'inventory-pre-boot'},
                              {'stage': 'inventory-pre-test'}])
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[0], ['xcrun', 'simctl', 'create', NAME, TYPE, RUNTIME])
            self.assertEqual(commands[-1], ['flutter', '--no-version-check', 'test', '--no-pub', 'integration_test/native_storage_test.dart', '-d', UUID, '--dart-define=NATIVE_STORAGE_SMOKE=true', '--reporter', 'expanded'])
            self.assertEqual([call.kwargs['seconds'] for call in run.call_args_list], [60, 30, 180, 600])
            self.assertEqual(smoke.load(path / 'owned.json'), STATE)
            self.assertFalse((path / 'creation-attempted').exists())

    def test_post_boot_inventory_failure_never_starts_test_and_keeps_ownership(self):
        before = data()
        before['devices'] = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            fake_uuid = type('FakeUUID', (), {'hex': 'a' * 32})()
            with patch.object(smoke.uuid, 'uuid4', return_value=fake_uuid), patch.object(
                    smoke, 'inventory', side_effect=[
                        before, data(), data(), smoke.Failure('post-boot inventory timeout')
                    ]) as inventory, patch.object(smoke, 'run') as run:
                with self.assertRaises(smoke.Failure):
                    smoke.execute(path)
            self.assertEqual(inventory.call_count, 4)
            self.assertEqual([call.kwargs['stage'] for call in run.call_args_list],
                             ['create', 'boot', 'boot-wait'])
            self.assertEqual(smoke.load(path / 'owned.json'), STATE)
            self.assertFalse((path / 'creation-attempted').exists())

    def test_failed_create_never_creates_ownership_record(self):
        before = data()
        before['devices'] = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(smoke, 'inventory', return_value=before), patch.object(smoke, 'run', side_effect=smoke.Failure('failed')):
                with self.assertRaises(smoke.Failure):
                    smoke.execute(path)
            self.assertFalse((path / 'owned.json').exists())
            self.assertTrue((path / 'creation-attempted').exists())

    def test_missing_post_shutdown_confirmation_prevents_delete(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'owned.json', STATE)
            with patch.object(smoke, 'inventory', return_value=data('Booted')), patch.object(smoke, 'run') as run:
                with self.assertRaises(smoke.Failure):
                    smoke.cleanup(path)
                self.assertEqual(run.call_count, 1)

    def test_failed_parent_terminates_only_owned_group(self):
        process = Mock(pid=12345)
        process.wait.return_value = 7
        with patch.object(smoke.subprocess, 'Popen', return_value=process) as popen, patch.object(smoke.os, 'killpg') as kill:
            with self.assertRaisesRegex(smoke.Failure, 'stage=test reason=exit exit=7'):
                smoke.run(['synthetic-command'], stage='test')
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            self.assertEqual([c.args for c in kill.call_args_list], [
                (12345, smoke.signal.SIGTERM), (12345, smoke.signal.SIGKILL)])
            self.assertEqual([c.kwargs['timeout'] for c in process.wait.call_args_list], [10, 10, 10])

    def test_cleanup_failure_preserves_original_failure_without_leaking(self):
        cases = [
            (smoke.subprocess.TimeoutExpired('SECRET', 10), 'timeout', 'unknown'),
            (KeyboardInterrupt('SECRET'), 'interrupted', 'unknown'),
            (7, 'exit', '7'),
        ]
        for outcome, reason, code in cases:
            with self.subTest(reason=reason):
                process = Mock(pid=12345)
                if isinstance(outcome, BaseException):
                    process.wait.side_effect = outcome
                else:
                    process.wait.return_value = outcome
                with patch.object(smoke.subprocess, 'Popen', return_value=process), patch.object(
                        smoke, 'terminate_owned_group', side_effect=OSError('SECRET')) as cleanup:
                    with self.assertRaises(smoke.Failure) as failure:
                        smoke.run(['SECRET'], stage='inventory-pre-test')
                    self.assertEqual(str(failure.exception),
                                     f'stage=inventory-pre-test reason={reason} exit={code} cleanup=failed; output suppressed')
                    cleanup.assert_called_once_with(process)
                    self.assertIsNone(failure.exception.__cause__)
                    self.assertTrue(failure.exception.__suppress_context__)

    def test_success_does_not_stop_shared_services_or_group(self):
        process = Mock(pid=12345)
        process.wait.return_value = 0
        with patch.object(smoke.subprocess, 'Popen', return_value=process), patch.object(smoke.os, 'killpg') as kill:
            smoke.run(['synthetic-command'], stage='boot')
            kill.assert_not_called()

    def test_timeout_kills_group_with_bounded_waits(self):
        process = Mock(pid=12345)
        process.wait.side_effect = [smoke.subprocess.TimeoutExpired('hidden', 1),
                                    smoke.subprocess.TimeoutExpired('hidden', 10), -9]
        with patch.object(smoke.subprocess, 'Popen', return_value=process), patch.object(smoke.os, 'killpg') as kill:
            with self.assertRaisesRegex(smoke.Failure, 'stage=boot-wait reason=timeout'):
                smoke.run(['synthetic-command'], seconds=1, stage='boot-wait')
            self.assertEqual(kill.call_count, 2)
            self.assertEqual([c.kwargs['timeout'] for c in process.wait.call_args_list], [1, 10, 10])

    def test_inventory_cold_bound_is_explicit_not_sticky(self):
        with patch.object(smoke, 'run', return_value={'devices': {}}) as run:
            smoke.inventory(cold=True, stage='inventory-initial')
            smoke.inventory(stage='inventory-created')
            smoke.inventory(stage='cleanup-inventory-owned')
        self.assertEqual([call.kwargs['seconds'] for call in run.call_args_list], [240, 10, 60])
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ['xcrun', 'simctl', 'list', '--json'],
            ['xcrun', 'simctl', 'list', 'devices', '--json'],
            ['xcrun', 'simctl', 'list', 'devices', '--json']])
        self.assertEqual([call.kwargs['stage'] for call in run.call_args_list],
                         ['inventory-initial', 'inventory-created', 'cleanup-inventory-owned'])

    def test_cold_inventory_failure_does_not_retry_or_create(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(smoke, 'inventory', side_effect=smoke.Failure('timeout')) as inventory, patch.object(smoke, 'run') as run:
                with self.assertRaises(smoke.Failure):
                    smoke.execute(path)
                inventory.assert_called_once_with(cold=True, stage='inventory-initial')
                run.assert_not_called()
            self.assertEqual(list(path.iterdir()), [])

    def test_interruption_distinct_from_timeout_and_cleans_group(self):
        process = Mock(pid=12345)
        process.wait.side_effect = [KeyboardInterrupt('SECRET'), -15, -15]
        with patch.object(smoke.subprocess, 'Popen', return_value=process), patch.object(smoke.os, 'killpg') as kill:
            with self.assertRaisesRegex(smoke.Failure, '^stage=inventory-initial reason=interrupted exit=unknown; output suppressed$'):
                smoke.run(['synthetic-command'], seconds=60, stage='inventory-initial')
            self.assertEqual([c.args for c in kill.call_args_list], [
                (12345, smoke.signal.SIGTERM), (12345, smoke.signal.SIGKILL)])
            self.assertEqual([c.kwargs['timeout'] for c in process.wait.call_args_list], [60, 10, 10])

    def test_phase_specific_inventory_bounds(self):
        for stage in smoke.DEVICE_PHASES:
            with self.subTest(stage=stage), patch.object(smoke, 'run', return_value={'devices': {}}) as run:
                smoke.inventory(stage=stage)
                run.assert_called_once_with(['xcrun', 'simctl', 'list', 'devices', '--json'],
                                            capture=True, stage=stage,
                                            seconds={'inventory-pre-test': 180, 'cleanup-inventory-owned': 60}.get(stage, 10))

    def test_inventory_rejects_unknown_or_widened_phase(self):
        for kwargs in [{'stage': 'SECRET'}, {'stage': 'inventory-initial'},
                       {'stage': 'cleanup-inventory-owned', 'cold': True}]:
            with patch.object(smoke, 'run') as run:
                with self.assertRaises(smoke.Failure):
                    smoke.inventory(**kwargs)
                run.assert_not_called()

    def test_invalid_inventory_cannot_establish_absence(self):
        for invalid in [{}, [], {'devices': []}, {'devices': {RUNTIME: None}},
                        {'devices': {RUNTIME: [None]}}, {'devices': {RUNTIME: [{}]}},
                        {'devices': {RUNTIME: [{'udid': 'SECRET'}]}}]:
            with self.subTest(value=invalid), patch.object(smoke, 'run', return_value=invalid):
                with self.assertRaisesRegex(smoke.Failure, '^stage=cleanup-inventory-owned invalid device inventory'):
                    smoke.inventory(stage='cleanup-inventory-owned')

    def test_noncanonical_uuid_cannot_hide_owned_device_at_cleanup(self):
        for value in [UUID.lower(), UUID.replace('-', '')]:
            item = data('Booted')
            item['devices'][RUNTIME][0]['udid'] = value
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                smoke.save(path / 'owned.json', STATE)
                output = io.StringIO()
                with patch.object(smoke, 'run', return_value=item) as run, contextlib.redirect_stdout(output):
                    with self.assertRaisesRegex(smoke.Failure, '^stage=cleanup-inventory-owned invalid device inventory identity$'):
                        smoke.cleanup(path)
                    run.assert_called_once_with(['xcrun', 'simctl', 'list', 'devices', '--json'],
                                                capture=True, stage='cleanup-inventory-owned', seconds=60)
                self.assertEqual(output.getvalue(), '')

    def test_duplicate_json_keys_cannot_hide_owned_device_at_cleanup(self):
        device = json.dumps(data('Booted')['devices'][RUNTIME][0])
        runtime = json.dumps(RUNTIME)
        malformed = [
            '{"devices":{' + runtime + ':[' + device + ']},"devices":{}}',
            '{"devices":{' + runtime + ':[' + device + '],' + runtime + ':[]}}',
        ]
        for raw in malformed:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                smoke.save(path / 'owned.json', STATE)
                process = Mock(pid=12345)
                process.wait.return_value = 0

                def launch(args, **kwargs):
                    kwargs['stdout'].write(raw.encode())
                    return process

                output = io.StringIO()
                with patch.object(smoke.subprocess, 'Popen', side_effect=launch) as popen, contextlib.redirect_stdout(output):
                    with self.assertRaisesRegex(smoke.Failure, '^stage=cleanup-inventory-owned invalid inventory JSON$'):
                        smoke.cleanup(path)
                    self.assertEqual(popen.call_count, 1)
                    self.assertEqual(popen.call_args.args[0], ['xcrun', 'simctl', 'list', 'devices', '--json'])
                self.assertRegex(output.getvalue(),
                                 r'^TIMING: stage=cleanup-inventory-owned elapsed_ms=[0-9]+\n$')

    def test_cleanup_inventory_phases_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            smoke.save(path / 'owned.json', STATE)
            with patch.object(smoke, 'inventory', side_effect=[data('Booted'), data(), {'devices': {}}]) as inventory, patch.object(smoke, 'run'):
                smoke.cleanup(path)
            self.assertEqual([call.kwargs['stage'] for call in inventory.call_args_list],
                             ['cleanup-inventory-owned', 'cleanup-inventory-stopped',
                              'cleanup-inventory-absent'])

    def test_stage_and_exit_diagnostics_are_allowlisted(self):
        for stage in smoke.STAGES:
            self.assertIn('stage=' + stage, str(smoke.command_failure(stage, 'exit', 23)))
        self.assertNotIn('SECRET', str(smoke.command_failure('SECRET', 'exit', 23)))
        for invalid in [999999, -999999, 'SECRET', True, None]:
            self.assertIn('exit=unknown', str(smoke.command_failure('test', 'exit', invalid)))
        with patch.object(smoke.subprocess, 'Popen') as popen:
            with self.assertRaises(smoke.Failure):
                smoke.run(['anything'], stage='SECRET')
            popen.assert_not_called()

    def test_launch_failure_does_not_leak_exception_or_kill(self):
        with patch.object(smoke.subprocess, 'Popen', side_effect=OSError('SECRET')), patch.object(smoke.os, 'killpg') as kill:
            with self.assertRaisesRegex(smoke.Failure, '^stage=create reason=launch exit=unknown; output suppressed$'):
                smoke.run(['anything'], stage='create')
            kill.assert_not_called()

    def test_timing_is_allowlisted_and_preserves_failure(self):
        for outcome in [None, smoke.Failure('SECRET'), KeyboardInterrupt('SECRET')]:
            output = io.StringIO()
            with self.subTest(outcome=type(outcome).__name__), patch.object(
                    smoke, '_run', side_effect=outcome) as execute, patch.object(
                    smoke.time, 'monotonic', side_effect=[100.0, 101.25]), contextlib.redirect_stdout(output):
                if outcome is None:
                    smoke.run(['SECRET'], stage='test')
                else:
                    with self.assertRaises(type(outcome)) as caught:
                        smoke.run(['SECRET'], stage='test')
                    self.assertIs(caught.exception, outcome)
                execute.assert_called_once_with(['SECRET'], 10, False, stage='test')
            self.assertEqual(output.getvalue(), 'TIMING: stage=test elapsed_ms=1250\n')

    def test_timing_bounds_and_invalid_stage_do_not_leak(self):
        for finish, expected in [(99.0, 0), (1000000.0, 86400000)]:
            output = io.StringIO()
            with patch.object(smoke, '_run'), patch.object(
                    smoke.time, 'monotonic', side_effect=[100.0, finish]), contextlib.redirect_stdout(output):
                smoke.run(['SECRET'], stage='boot')
            self.assertEqual(output.getvalue(), f'TIMING: stage=boot elapsed_ms={expected}\n')
        output = io.StringIO()
        with patch.object(smoke, '_run') as execute, contextlib.redirect_stdout(output):
            with self.assertRaises(smoke.Failure):
                smoke.run(['SECRET'], stage='SECRET')
            execute.assert_not_called()
        self.assertEqual(output.getvalue(), '')

    def test_bounded_runner_suppresses_output(self):
        self.assertIsNone(smoke.run(['python3', '-c', "print('SYNTHETIC')"], seconds=5, stage='test'))
        with self.assertRaises(smoke.Failure):
            smoke.run(['python3', '-c', 'import time; time.sleep(5)'], seconds=0.02, stage='test')


if __name__ == '__main__':
    unittest.main()
