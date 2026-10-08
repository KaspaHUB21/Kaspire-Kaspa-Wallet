import {z} from 'zod';
// Standalone Kaspire service: fail closed without an explicit private secret.
export const env=z.object({
 NODE_ENV:z.enum(['development','test','production']).default('production'),
 DATABASE_URL:z.string().min(1),
 SESSION_SECRET:z.string().min(32),
 APP_URL:z.literal('https://kaspire.kaslab.space').default('https://kaspire.kaslab.space'),
 KASPACOM_API_BASE_URL:z.string().url().optional().or(z.literal('')),
 KASPACOM_MARKETPLACE_BASE_URL:z.string().url().default('https://kaspa.com'),
}).parse(process.env);
