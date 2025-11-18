const functions = require('firebase-functions');
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions");
const { defineString } = require("firebase-functions/params");
const admin = require('firebase-admin');
const nodemailer = require('nodemailer');

admin.initializeApp();
const db = admin.firestore();

const mailUserParam = defineString('MAIL_USER', { default: '' });
const mailPassParam = defineString('MAIL_PASS', { default: '' });
const mailFromParam = defineString('MAIL_FROM', { default: '' });
const mailServiceParam = defineString('MAIL_SERVICE', { default: '' });
const mailHostParam = defineString('MAIL_HOST', { default: '' });
const mailPortParam = defineString('MAIL_PORT', { default: '' });
const mailSecureParam = defineString('MAIL_SECURE', { default: '' });

const parseBoolean = (value) => {
  if (typeof value === 'boolean') return value;
  const normalized = String(value || '').trim().toLowerCase();
  if (!normalized) return null;
  return ['true', '1', 'yes', 'y'].includes(normalized);
};

const parsePort = (value) => {
  const num = parseInt(value, 10);
  return Number.isFinite(num) && num > 0 ? num : undefined;
};

let cachedMailTransporter = null;
let cachedMailFrom = 'no-reply@example.com';

const resolveMailer = () => {
  if (cachedMailTransporter !== null) {
    return { transporter: cachedMailTransporter, from: cachedMailFrom };
  }

  const mailConfig = {
    user: mailUserParam.value(),
    pass: mailPassParam.value(),
    from: mailFromParam.value(),
    service: mailServiceParam.value(),
    host: mailHostParam.value(),
    port: parsePort(mailPortParam.value()),
    secure: parseBoolean(mailSecureParam.value()),
  };

  const mailEnabled = Boolean(mailConfig.user && mailConfig.pass);

  if (!mailEnabled) {
    cachedMailTransporter = null;
    cachedMailFrom = 'no-reply@example.com';
    logger.warn('Mail configuration not found. Guard creation emails will be skipped until MAIL_USER and MAIL_PASS are set (for example via .env).');
    return { transporter: null, from: cachedMailFrom };
  }

  cachedMailFrom = mailConfig.from || mailConfig.user || 'no-reply@example.com';
  cachedMailTransporter = nodemailer.createTransport({
    service: mailConfig.service || 'gmail',
    host: mailConfig.host || undefined,
    port: mailConfig.port,
    secure: mailConfig.secure ?? false,
    auth: {
      user: mailConfig.user,
      pass: mailConfig.pass,
    },
  });

  return { transporter: cachedMailTransporter, from: cachedMailFrom };
};

exports.updateGuardStatusesV2 = onSchedule({
  schedule: "every 5 minutes",
  timeZone: "Asia/Manila",
  region: "asia-southeast1",
  timeoutSeconds: 180,
}, async () => {
  const tz = "Asia/Manila";
  const now = new Date(new Date().toLocaleString("en-US", { timeZone: tz }));
  const currentDateStr = now.toISOString().split('T')[0]; // now is in Manila time
  const currentMinutes = now.getHours() * 60 + now.getMinutes();

  // Fetch all security accounts
  const accountsSnap = await db.collection('Accounts')
    .where('role', '==', 'Security')
    .get();

  // Start with everyone Off Duty by default
  const guardIdToStatus = new Map();
  accountsSnap.forEach(doc => {
    const data = doc.data() || {};
    const userFacingId = (data.guard_id || '').toString();
    if (userFacingId) guardIdToStatus.set(userFacingId, { status: 'Off Duty', scheduleType: null });
  });

  // Get today's schedules and mark active ones On Duty
  const schedulesSnap = await db.collection('Schedules')
    .where('date', '==', currentDateStr)
    .get();

  schedulesSnap.forEach(doc => {
    const s = doc.data() || {};
    if (typeof s.start_time !== 'string' || typeof s.end_time !== 'string') return;
    const [sh, sm] = s.start_time.split(':').map(Number);
    const [eh, em] = s.end_time.split(':').map(Number);
    if ([sh, sm, eh, em].some(n => Number.isNaN(n))) return;
    const start = sh * 60 + sm;
    const end = eh * 60 + em;
    const overnight = end <= start;
    const withinSameDay = !overnight && currentMinutes >= start && currentMinutes < end;
    const withinOvernight = overnight && (currentMinutes >= start || currentMinutes < end);
    const isOnDuty = withinSameDay || withinOvernight;
    const gid = (s.guard_id || '').toString();
    if (!gid) return;
    if (isOnDuty) guardIdToStatus.set(gid, { status: 'On Duty', scheduleType: s.schedule_type || 'daily' });
  });

  // Write statuses for all security accounts
  const batch = db.batch();
  accountsSnap.forEach(doc => {
    const data = doc.data() || {};
    const gid = (data.guard_id || '').toString();
    if (!gid) return;
    const computed = guardIdToStatus.get(gid) || { status: 'Off Duty', scheduleType: null };
    batch.update(doc.ref, {
      status: computed.status,
      last_status_update: admin.firestore.FieldValue.serverTimestamp(),
      schedule_type: computed.scheduleType,
    });
  });
  await batch.commit();
  return null;
});


exports.resetCheckpointStatusesDailyV2 = onSchedule({
    schedule: "0 0 * * *",
    timeZone: "Asia/Manila",
    region: "asia-southeast1",
    timeoutSeconds: 300,
  }, async (event) => {
    logger.info('Running daily checkpoint status reset V2...', { structuredData: true });

    const checkpointsRef = db.collection('Checkpoints');
    try {
      const snapshot = await checkpointsRef.get();
      if (snapshot.empty) {
        logger.info('No checkpoints found to reset.', {fn: 'resetCheckpointStatusesDailyV2'});
        return null;
      }

      const batch = db.batch();
      snapshot.docs.forEach(doc => {
        logger.info(`Resetting status for checkpoint: ${doc.id}`, {fn: 'resetCheckpointStatusesDailyV2'});
        batch.update(doc.ref, {
          status: 'Not Yet Scanned',
          lastScannedAt: null,
          remarks: null,
          lastScannedById: null,
          lastScannedByName: null,
          lastScannedBy: null,
        });
      });

      await batch.commit();
      logger.info(`Successfully reset statuses for checkpoints.`, {count: snapshot.docs.length, fn: 'resetCheckpointStatusesDailyV2'});
      return null;
    } catch (error) {
      logger.error('Error resetting checkpoint statuses:', error, {fn: 'resetCheckpointStatusesDailyV2'});
      throw error;
    }
});



exports.moveEndedSchedulesV1 = onSchedule({
  schedule: "every 5 minutes",
  timeZone: "Asia/Manila",
  region: "asia-southeast1",
  timeoutSeconds: 180,
}, async () => {
  const tz = "Asia/Manila";
  const now = new Date(new Date().toLocaleString("en-US", { timeZone: tz }));
  const todayStr = now.toISOString().split('T')[0];
  const currentMinutes = now.getHours() * 60 + now.getMinutes();

  // Compute yesterday string in Manila time
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  const yesterdayStr = yesterday.toISOString().split('T')[0];

  // Fetch today's schedules (same-day shifts) and yesterday's schedules (overnight shifts)
  const [todaySnap, yesterdaySnap] = await Promise.all([
    db.collection('Schedules').where('date', '==', todayStr).get(),
    db.collection('Schedules').where('date', '==', yesterdayStr).get(),
  ]);

  const toMove = [];

  // Helper to evaluate a schedule doc
  const evaluateDoc = (doc, isFromYesterday) => {
    const s = doc.data();
    if (!s || typeof s.start_time !== 'string' || typeof s.end_time !== 'string') return;
    const [sh, sm] = s.start_time.split(':').map(Number);
    const [eh, em] = s.end_time.split(':').map(Number);
    if ([sh, sm, eh, em].some(n => Number.isNaN(n))) return;

    const start = sh * 60 + sm;
    const end = eh * 60 + em;
    const overnight = end <= start;

    const endedSameDay = !overnight && !isFromYesterday && currentMinutes >= end;
    const endedOvernight = overnight && isFromYesterday && currentMinutes >= end;

    if (endedSameDay || endedOvernight) {
      toMove.push(doc);
    }
  };

  todaySnap.forEach(doc => evaluateDoc(doc, /*isFromYesterday=*/false));
  yesterdaySnap.forEach(doc => evaluateDoc(doc, /*isFromYesterday=*/true));

  if (toMove.length === 0) {
    logger.info('No schedules to move to Ended Schedules at this time.');
    return null;
  }

  // Move in batches of up to 400 operations (since each move counts as 2 ops: create+delete)
  const chunkSize = 200; // 200 docs -> 400 ops
  for (let i = 0; i < toMove.length; i += chunkSize) {
    const chunk = toMove.slice(i, i + chunkSize);
    const batch = db.batch();
    for (const doc of chunk) {
      const data = doc.data();
      const endedRef = db.collection('EndedSchedules').doc(doc.id);
      batch.set(endedRef, {
        ...data,
        ended_at: admin.firestore.FieldValue.serverTimestamp(),
        source_collection: 'Schedules',
        schedule_type: data.schedule_type || 'daily', // Track schedule type
      });
      batch.delete(doc.ref);
    }
    await batch.commit();

    // After moving, reset checkpoints for each ended schedule
    for (const doc of chunk) {
      const data = doc.data() || {};
      const checkpoints = Array.isArray(data.checkpoints) ? data.checkpoints : [];
      if (!checkpoints.length) continue;

      // Do batched updates with safety margin under 500 ops
      const cpChunkSize = 400;
      for (let j = 0; j < checkpoints.length; j += cpChunkSize) {
        const cpChunk = checkpoints.slice(j, j + cpChunkSize);
        const cpBatch = db.batch();
        cpChunk.forEach((cpIdRaw) => {
          try {
            const cpId = String(cpIdRaw);
            if (!cpId) return;
            const cpRef = db.collection('Checkpoints').doc(cpId);
            cpBatch.update(cpRef, {
              status: 'Not Yet Scanned',
              lastScannedAt: null,
              remarks: null,
              lastScannedById: null,
              lastScannedByName: null,
              lastScannedBy: null,
            });
          } catch (e) {
            logger.warn('Skipping invalid checkpoint id during reset', { value: cpIdRaw, error: String(e) });
          }
        });
        await cpBatch.commit();
      }

      logger.info('Reset checkpoints for ended schedule', { scheduleId: doc.id, count: checkpoints.length });
    }
  }

  logger.info(`Moved ${toMove.length} schedules to 'EndedSchedules'.`);
  return null;
});

// New function to manage weekly and monthly schedules
exports.manageRecurringSchedules = onSchedule({
  schedule: "0 0 * * *", // Run daily at midnight
  timeZone: "Asia/Manila",
  region: "asia-southeast1",
  timeoutSeconds: 300,
}, async () => {
  const tz = "Asia/Manila";
  const now = new Date(new Date().toLocaleString("en-US", { timeZone: tz }));
  const todayStr = now.toISOString().split('T')[0];
  
  logger.info('Managing recurring schedules...', { date: todayStr });

  try {
    // Check for active weekly schedules that need daily schedules created
    const weeklySchedulesSnap = await db.collection('WeeklySchedules')
      .where('is_active', '==', true)
      .get();

    for (const weeklyDoc of weeklySchedulesSnap.docs) {
      const weeklyData = weeklyDoc.data();
      const weekStartDate = new Date(weeklyData.week_start_date);
      const today = new Date(todayStr);
      
      // Check if today falls within this week's range
      const weekEnd = new Date(weekStartDate);
      weekEnd.setDate(weekStartDate.getDate() + 6);
      
      if (today >= weekStartDate && today <= weekEnd) {
        // Check if daily schedule already exists for today
        const existingDailySnap = await db.collection('Schedules')
          .where('date', '==', todayStr)
          .where('parent_weekly_schedule_id', '==', weeklyDoc.id)
          .limit(1)
          .get();

        if (existingDailySnap.empty) {
          // Create daily schedules for today
          const batch = db.batch();
          for (const guardId of weeklyData.guard_ids) {
            const scheduleRef = db.collection('Schedules').doc();
            batch.set(scheduleRef, {
              'guard_id': guardId,
              'date': todayStr,
              'start_time': weeklyData.start_time,
              'end_time': weeklyData.end_time,
              'duty': true,
              'created_at': admin.firestore.FieldValue.serverTimestamp(),
              'checkpoints': weeklyData.checkpoints || [],
              'parent_weekly_schedule_id': weeklyDoc.id,
              'schedule_type': 'weekly',
            });
          }
          await batch.commit();
          logger.info(`Created daily schedules for weekly schedule ${weeklyDoc.id} on ${todayStr}`);
        }
      }
    }

    // Check for active monthly schedules that need daily schedules created
    const monthlySchedulesSnap = await db.collection('MonthlySchedules')
      .where('is_active', '==', true)
      .get();

    for (const monthlyDoc of monthlySchedulesSnap.docs) {
      const monthlyData = monthlyDoc.data();
      const monthYear = monthlyData.month_year; // Format: YYYY-MM
      const todayMonthYear = todayStr.substring(0, 7); // Get YYYY-MM from today
      
      if (monthYear === todayMonthYear) {
        // Check if daily schedule already exists for today
        const existingDailySnap = await db.collection('Schedules')
          .where('date', '==', todayStr)
          .where('parent_monthly_schedule_id', '==', monthlyDoc.id)
          .limit(1)
          .get();

        if (existingDailySnap.empty) {
          // Create daily schedules for today
          const batch = db.batch();
          for (const guardId of monthlyData.guard_ids) {
            const scheduleRef = db.collection('Schedules').doc();
            batch.set(scheduleRef, {
              'guard_id': guardId,
              'date': todayStr,
              'start_time': monthlyData.start_time,
              'end_time': monthlyData.end_time,
              'duty': true,
              'created_at': admin.firestore.FieldValue.serverTimestamp(),
              'checkpoints': monthlyData.checkpoints || [],
              'parent_monthly_schedule_id': monthlyDoc.id,
              'schedule_type': 'monthly',
            });
          }
          await batch.commit();
          logger.info(`Created daily schedules for monthly schedule ${monthlyDoc.id} on ${todayStr}`);
        }
      }
    }

    logger.info('Recurring schedule management completed successfully');
    return null;
  } catch (error) {
    logger.error('Error managing recurring schedules:', error);
    throw error;
  }
});


exports.sendSecurityGuardAccountEmail = onDocumentCreated(
  {
    region: "asia-southeast1",
    timeoutSeconds: 120,
    memory: "256MiB",
    document: "Accounts/{accountId}",
  },
  async (event) => {
    const snap = event.data;
    const data = snap?.data();
    if (!data) {
      logger.warn('Accounts onCreate triggered with no data', { accountId: event.params.accountId });
      return null;
    }

    const role = String(data.role || '').toLowerCase();
    if (role !== 'security') {
      return null;
    }

    const email = data.email;
    if (!email) {
      logger.warn('Security guard account created without email; cannot send notification', { accountId: event.params.accountId });
      return null;
    }

    const { transporter: mailTransporter, from: mailFrom } = resolveMailer();

    if (!mailTransporter) {
      logger.error('Mail transporter not configured. Skipping guard account email.', { accountId: event.params.accountId });
      return null;
    }

    const displayName = (data.name || `${data.first_name || ''} ${data.last_name || ''}`.trim() || 'Security Guard').trim();
    const guardId = data.guard_id || event.params.accountId;
    const position = data.position || 'Security Guard';
    const contact = data.contact || 'Not specified';
    const address = data.address || 'Not specified';
    const sex = data.sex || 'Not specified';
    const accountStatus = data.account_status || 'Active';
    const status = data.status || 'Off Duty';
    const initialPassword = data.initial_password || 'Provided separately';

    const subject = 'Security Guard Account Created';
    const bodyText = [
      `Dear ${displayName},`,
      '',
      'Your security guard account has been created. Please review the information below and keep it for your records.',
      '',
      `Name: ${displayName}`,
      `Email: ${email}`,
      `Temporary Password: ${initialPassword}`,
      `Guard ID: ${guardId}`,
      `Position: ${position}`,
      `Contact Number: ${contact}`,
      `Address: ${address}`,
      `Sex: ${sex}`,
      `Account Status: ${accountStatus}`,
      `Current Duty Status: ${status}`,
      '',
      'For security purposes, change your password after your first login and do not share these credentials.',
      '',
      'Regards,',
      'Security Command Center',
    ].join('\n');

    const bodyHtml = `
      <div style="font-family: Arial, sans-serif; color:#1a1a1a; background:#f7f9fc; padding:24px;">
        <p>Dear ${displayName},</p>
        <p>Your security guard account has been created. Please review the information below and keep it for your records.</p>
        <table style="border-collapse:collapse; width:100%; max-width:520px;">
          <tbody>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Name</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${displayName}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Email</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${email}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Temporary Password</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${initialPassword}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Guard ID</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${guardId}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Position</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${position}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Contact Number</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${contact}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Address</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${address}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Sex</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${sex}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Account Status</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${accountStatus}</td>
            </tr>
            <tr>
              <td style="padding:6px 12px; border:1px solid #d0d7de; font-weight:600;">Current Duty Status</td>
              <td style="padding:6px 12px; border:1px solid #d0d7de;">${status}</td>
            </tr>
          </tbody>
        </table>
        <p style="margin-top:18px;">For security purposes, change your password after your first login and do not share these credentials.</p>
        <p style="margin-top:24px;">Regards,<br/>Security Command Center</p>
      </div>
    `;

    try {
      await mailTransporter.sendMail({
        from: mailFrom,
        to: email,
        subject,
        text: bodyText,
        html: bodyHtml,
      });
      logger.info('Sent security guard account email', { accountId: event.params.accountId, email });
    } catch (error) {
      logger.error('Failed to send security guard account email', {
        accountId: event.params.accountId,
        email,
        error: error.message,
      });
    }
    return null;
  }
);

