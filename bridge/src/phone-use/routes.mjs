// The phone's half of phone use: its push-to-start token, each activity's
// update token, its own request's state, and the owner's answer from the Live Activity.
import { parseObjectBody } from '../routes/state-file.mjs';

const ID = '(pu_[0-9a-f]{16})';
export function phoneUseRoutes({ service }) {
  return [
    { method: 'PUT', path: '/v1/phone-use/start-token', auth: true, scope: 'sessions:write',
      handler: ({ device, rawBody }) => { const body = parseObjectBody(rawBody);
        return { status: 200, data: service.setStartToken({ deviceId: device.id, platform: device.platform, token: body.token, environment: body.environment, wakeToken: body.wakeToken }) }; } },
    { method: 'PUT', pattern: new RegExp(`^/v1/phone-use/requests/${ID}/activity-token$`), auth: true, scope: 'sessions:write',
      handler: ({ params, device, rawBody }) => ({ status: 200, data: service.setActivityToken({ id: params[0], deviceId: device.id, token: parseObjectBody(rawBody).token }) }) },
    { method: 'GET', pattern: new RegExp(`^/v1/phone-use/requests/${ID}$`), auth: true, scope: 'sessions:write',
      handler: ({ params, device }) => ({ status: 200, data: service.statusFor({ id: params[0], deviceId: device.id }) }) },
    { method: 'POST', pattern: new RegExp(`^/v1/phone-use/requests/${ID}/answer$`), auth: true, scope: 'sessions:write',
      handler: ({ params, device, rawBody }) => ({ status: 200, data: service.answer({ id: params[0], deviceId: device.id, answer: parseObjectBody(rawBody).answer }) }) },
  ];
}
