import reference from '../../../../crates/kaspa_secure_core/src/kcc20_standard_template.json';
import ten from '../../../../crates/kaspa_secure_core/src/kcc20_reference_10_template.json';

// Limits belong to a locally pinned program, never to editable indexer limits.
export const KCC20_PROGRAMS = Object.freeze([
  Object.freeze({id:'argent-kcc20-c8a0871',hash:'9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7',maxInputs:3,maxOutputs:3,template:reference}),
  Object.freeze({id:'argent-kcc20-c8a0871-10x10',hash:ten.templateHash,maxInputs:10,maxOutputs:10,template:ten}),
]);
export function kcc20Program(hash:string) {
  const p=KCC20_PROGRAMS.find(p=>p.hash===hash);
  if(!p)throw Error('Unsupported KCC20 program configuration.');
  return p;
}
export function kcc20TokenProgram(row:any) {
  const hash=row?.template_hash??row?.program?.template_hash??row?.configuration?.template_hash;
  if(hash!==undefined)return KCC20_PROGRAMS.find(p=>p.hash===hash);
  return row?.profile_id==='KCC20PublicMint@c8a0871'?KCC20_PROGRAMS[0]:undefined;
}
