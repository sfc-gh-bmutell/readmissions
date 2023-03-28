--Readmissions 3: Predicting Patients and Preparation for Outreach
--In this vignette we will score our new patients for readmission, create and apply data governance policies to limit the data viewable by our outreach coordinator, create a compute cluster that can scale out to meet the concurrency needs of reporting, and prepare data for visualization in Tableau

--Set context for this vignette
use role datasci;
use schema analytics.readmit;
use warehouse datasci_wh;

--See our model in the internal stage   
ls @readmissions_model_stage;

--Score new patients with the UDF leveraging our logistic regression model
alter warehouse datasci_wh 
    set warehouse_size=large;
    
create or replace table new_patient_predictions_SS as
    select *, 
        udf_logistic_readmit_predict(PATIENT_AGE, BMI, LENGTH_OF_STAY, ORDER_SET_USED, CHRONIC_CONDITIONS_NUMBER, SBUX_COUNT) as PREDICTED_READMISSION               
    from new_patients_imp;

--What proportion of our new patient have been predicted to be readmitted? 
select distinct predicted_readmission, count(*) as count
    from new_patient_predictions_SS 
    group by predicted_readmission;
    

--Create limited, outreach coordinator role for viewing predictions and contacting those patients
--Grant our outreach coordinator the appropriate permissions
use role accountadmin;    
create or replace role outreach_role;
grant role outreach_role to user bmutell;

use role datasci;
use schema analytics.readmit;
grant usage on database analytics to role outreach_role;
grant usage on schema readmit to role outreach_role;
grant select on table new_patient_predictions_SS to role outreach_role;

--Create an isolated multi-cluster warehouse for the presentation layer
use role sysadmin;
create or replace warehouse pres_wh
    warehouse_size=xsmall
    min_cluster_count=1
    max_cluster_count=4
    scaling_policy=standard
    auto_suspend=600
    auto_resume=true;
grant usage on warehouse pres_wh to role datasci;
grant usage on warehouse pres_wh to role outreach_role;

--Create and apply masking policies for sensitive data
use role datasci;
use schema analytics.readmit;

-- Remove masking policies from previous runs
-- alter table new_patient_predictions_SS modify
--     column patient_age unset masking policy, 
--     column marital_status unset masking policy, 
--     column sdoh_flag unset masking policy,
--     column bmi unset masking policy,
--     column total_charges unset masking policy,
--     column address unset masking policy,
--     column phone unset masking policy,
--     column email unset masking policy,
--     column address unset masking policy;
-- alter table new_patient_predictions_ss drop row access policy readmission_RAP;



--Create simple masking policies for strings, float numerics, and rounding age
create or replace masking policy analytics.security.mask_string_simple as
  (val string) returns string ->
  case
    when current_role() in ('DATASCI', 'SYSADMIN', 'ACCOUNTADMIN') then val
      else '**masked**'
    end;
    
create or replace masking policy analytics.security.age_mask_simple as
  (val integer) returns integer ->
  case
    when current_role() in ('DATASCI', 'SYSADMIN', 'ACCOUNTADMIN') then val
      else concat(substr(val, 0, 1), 0)
    end;

create or replace masking policy analytics.security.mask_float_simple as
  (val float) returns float ->
  case
    when current_role() in ('DATASCI', 'SYSADMIN', 'ACCOUNTADMIN') then val
      else 999.999
    end;
    
--Create conditional masking policies based on contact preference
--We will only show the contact method info for the column specified in the contact_preference column
--Only show phone number when patient specified contact via phone or text
create or replace masking policy analytics.security.phone_mask as
    (val string, contact string) returns string ->
    case
        when current_role() in ('OUTREACH_ROLE') and contact in ('phone', 'text') then val
        when current_role() in ('DATASCI', 'SYSADMIN', 'ACCOUNTADMIN') then val
        else 'Phone Masked'
    end;

--Only show email when patient specified contact via email
create or replace masking policy analytics.security.email_mask as 
    (val string, contact string) returns string->
    case
        when current_role() in ('OUTREACH_ROLE') and contact in ('email') then val
        when current_role() in ('DATASCI', 'SYSADMIN', 'ACCOUNTADMIN') then val
        else 'Email Masked'
    end;

--Only show home address when patient specified contact via home visit
create or replace masking policy analytics.security.address_mask as 
    (val string, contact string) returns string->
    case
        when current_role() in ('OUTREACH_ROLE') and contact in ('home visit') then val
        when current_role() in ('DATASCI', 'SYSADMIN', 'ACCOUNTADMIN') then val
        else 'Address Masked'
    end;


--Apply masking policies to our table of predictions    
alter table new_patient_predictions_SS modify
    column patient_age set masking policy security.age_mask_simple, 
    column marital_status set masking policy security.mask_string_simple, 
    column sdoh_flag set masking policy security.mask_string_simple,
    column bmi set masking policy security.mask_float_simple,
    column total_charges set masking policy security.mask_float_simple,
    column phone set masking policy analytics.security.phone_mask using (phone, contact_preference),
    column email set masking policy analytics.security.email_mask using (email, contact_preference),
    column address set masking policy analytics.security.address_mask using (address, contact_preference); 
    

--Create and apply row access policy so outreach role can only see at-risk individuals
--We don't need out outreach coordinator to reach patients that aren't at risk
create or replace row access policy readmission_RAP as (predicted_readmission float) returns boolean ->
    case
        when current_role() = 'OUTREACH_ROLE' and predicted_readmission=1 then true
        when current_role() in ('OUTREACH_ROLE') then false
        else true
    end;
    
alter table new_patient_predictions_SS 
    add row access policy readmission_policy on (predicted_readmission);

--View table with our data scientist role
use role datasci;

--We can see all patients in the table (37,838)
select count(*) 
    from new_patient_predictions_SS;

--All of the columns we masked are viewable in the clear
select NPI, predicted_readmission, contact_preference, email, phone, address, bmi, patient_age, marital_status, sdoh_flag, total_charges
    from new_patient_predictions_SS
    limit 15;


--Switch to our limited role
use role outreach_role;
use warehouse pres_wh;
use schema analytics.readmit;

--Our outreach coordinator can only see the patients predicted as readmitted (7,013)
select count(*) 
    from new_patient_predictions_SS;

--Column masks are applied 
select NPI, predicted_readmission, contact_preference, email, phone, address, bmi, patient_age, marital_status, sdoh_flag, total_charges
    from new_patient_predictions_SS
    limit 15;

