--candidate number 221352

SET search_path TO mimiciii;


/* Question 1 */

--get demographic information for patient 
SELECT 
	FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) AS age,
	patients.gender,
	admissions.ethnicity,
	admissions.marital_status,
	admissions.religion,
	(admissions.dischtime - admissions.admittime) AS total_time,
	(icustays.outtime - icustays.intime) AS icutime,
	icustays.last_careunit,
	icustays.last_wardid

FROM patients
	INNER JOIN admissions
	ON admissions.subject_id = patients.subject_id
		INNER JOIN prescriptions
		ON admissions.hadm_id = prescriptions.hadm_id
			INNER JOIN icustays
			ON admissions.hadm_id = icustays.hadm_id
WHERE (prescriptions.drug_name_poe LIKE '%imvastatin' OR prescriptions.drug_name_generic LIKE '%imvastatin') AND
	  patients.subject_id = 42130
ORDER BY admissions.admittime DESC --put the hadm_id with the most recend date at the top and limit it to that time
LIMIT 1 
;
--saved as "demographic.csv"

-- get diagnoses name and code from diagnoses table 
SELECT diagnoses_icd.subject_id, 
	(diagnoses_icd.icd9_code || ': ' || d_icd_diagnoses.long_title) AS diagnoses
FROM diagnoses_icd
INNER JOIN d_icd_diagnoses
ON diagnoses_icd.icd9_code = d_icd_diagnoses.icd9_code
WHERE diagnoses_icd.subject_id = 42130;
--saved as "diagnoses.csv"


--Get the prescriptions for the patient
SELECT DISTINCT prescriptions.drug_name_generic, prescriptions.subject_id 
FROM prescriptions
WHERE prescriptions.drug_name_generic IS NOT NULL
AND prescriptions.subject_id = 42130;
--saved as "prescriptions.csv"

/* Question 2 */

--select the vital signs for the patient who has only had one hospital admission

SELECT DISTINCT chartevents.charttime, 
	chartevents.itemid, 
	d_items.label, 
	chartevents.valuenum
FROM chartevents
INNER JOIN d_items
ON chartevents.itemid = d_items.itemid
WHERE chartevents.subject_id = 42130 and

/* item id found from joining the d_items and chartevents to find the vitals measured
			 tempF = 223761, resp_rate = 220210, o2 220277, non_bp mean 220181, HR = 220045, BP aerterial mean = 220052 */
	(chartevents.itemid = 223761 OR 
	 chartevents.itemid = 220210 OR
	 chartevents.itemid = 220277 OR
	 chartevents.itemid = 220181 OR
	 chartevents.itemid = 220045 OR
	 chartevents.itemid = 220052
	)
GROUP BY chartevents.charttime, chartevents.itemid, d_items.label, chartevents.valuenum
ORDER BY d_items.label ASC;
--saved as "time_series.csv"

/* Question 3 */
--get the age group 60-65
WITH age_group(subject_id, hadm_id, gender, age, dod, hlos) AS (
SELECT DISTINCT patients.subject_id, 
	admissions.hadm_id,
	patients.gender,  
	FLOOR(EXTRACT (EPOCH FROM (admissions.admittime - patients.dob))/(24*60*60*365.25)) AS age,
	admissions.deathtime,
	ROUND(CAST(EXTRACT (EPOCH FROM (admissions.dischtime - admissions.admittime))/(24*60*60)as numeric),2) as LOS
FROM admissions
INNER JOIN patients 
ON admissions.subject_id = patients.subject_id
	--using FLOOR to get the age (rounding down if the float of the age is 65.8 e.g.)
WHERE FLOOR(EXTRACT (EPOCH FROM (admissions.admittime - patients.dob))/(24*60*60*365.25)) >= 60 and 
		FLOOR(EXTRACT (EPOCH FROM (admissions.admittime - patients.dob))/(24*60*60*365.25)) <= 65
),

--get the patients with a cardiac device
cardiac_dev(subject_id, hadm_id, gender, icd9_code, dod, hlos) AS (
SELECT DISTINCT age_group.subject_id, 
	age_group.hadm_id, 
	age_group.gender, 
	diagnoses_icd.icd9_code, 
	age_group.dod,
	age_group.hlos
FROM age_group
	INNER JOIN diagnoses_icd
	--getting only the hadm_id for when patients have been diagnoses with a cardiac device
	ON age_group.hadm_id = diagnoses_icd.hadm_id
	
WHERE diagnoses_icd.icd9_code LIKE 'V450%'
),

--check whether the patient has died within 6 hours
icustaytime(subject_id, hadm_id, gender, los, icu_id, d_in_icu, dod, hlos) AS (
SELECT cardiac_dev.subject_id, cardiac_dev.hadm_id, cardiac_dev.gender, 
	ROUND(CAST( icustays.los AS numeric),2), 
	icustays.icustay_id,
	
	--see if dod is with +/- 6 h of icu visit
	CASE 
	WHEN EXTRACT(EPOCH FROM (cardiac_dev.dod - icustays.outtime)/(60*60)) > 6 THEN 0
	WHEN EXTRACT(EPOCH FROM (cardiac_dev.dod - icustays.intime)/(60*60)) < -6 THEN 0
	-- need to exclude people with a NULL dod from being counted as dead
	WHEN EXTRACT(EPOCH FROM (cardiac_dev.dod - icustays.intime)/(60*60)) IS NULL THEN 0
	ELSE 1 END AS d_in_icu, 
	cardiac_dev.dod, 
	cardiac_dev.hlos

FROM cardiac_dev
INNER JOIN icustays
	ON icustays.hadm_id = cardiac_dev.hadm_id	
),

--total time per icustay admission
icutimeperadmit(hadm_id, timeper_admit ) AS (
SELECT DISTINCT  icustays.hadm_id, 
	--for each hospital admission id, I am summing up each icu
	ROUND( CAST( SUM(icustays.los) AS numeric),2) AS timeper_admit --as days
	
FROM icustays
GROUP BY icustays.hadm_id 

)

--GET THE TOTAL TIME PER HOSPITAL ADMISSION AND TIME FOR EACH ICU VISIT
SELECT DISTINCT icustaytime.hadm_id, icustaytime.gender,
	icutimeperadmit.timeper_admit, icustaytime.hlos, icustaytime.d_in_icu
FROM icustaytime
	INNER JOIN icutimeperadmit
	ON icustaytime.hadm_id = icutimeperadmit.hadm_id
ORDER BY icustaytime.hadm_id
; 
--saved table as "icu_stay_time.csv"

/* Question 4 */

WITH age_group(subject_id, hadm_id, gender, age, dod) AS (
SELECT patients.subject_id, 
	admissions.hadm_id, 
	patients.gender, 
	FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) as age,
	admissions.deathtime
FROM admissions
	INNER JOIN patients 
	ON admissions.subject_id = patients.subject_id
GROUP BY patients.subject_id, admissions.hadm_id, patients.gender, age, admissions.deathtime
HAVING FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) >= 60 and 
	FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) <= 65
),
--get the patients with a cardiac device
cardiac_dev(hadm_id, subject_id, gender, age, dod) as (
SELECT DISTINCT age_group.hadm_id, 
	age_group.subject_id, 
	age_group.gender, 
	age_group.age, 
	age_group.dod
FROM age_group
	INNER JOIN diagnoses_icd
	ON age_group.hadm_id = diagnoses_icd.hadm_id
WHERE diagnoses_icd.icd9_code LIKE 'V450%'
	 
), 

--find the visit for when a patient died
icustaytime(hadm_id, subject_id, gender, age, los, intime, icu_id, firsticu, d_in_icu ) as (
	--I want the stay id for the icu stay in which they died.
SELECT icustays.hadm_id,
	cardiac_dev.subject_id, 
	cardiac_dev.gender, 
	cardiac_dev.age,
	ROUND(CAST(icustays.los AS numeric),2),
	icustays.intime, 
	icustays.icustay_id,
	icustays.first_careunit,
	--see if dod is with +/- 6 h of icu visit
	CASE  
	WHEN EXTRACT(EPOCH FROM (cardiac_dev.dod - icustays.outtime)/(60*60)) >= 6 THEN 0
	WHEN EXTRACT(EPOCH FROM (cardiac_dev.dod - icustays.intime)/(60*60)) <= -6 THEN 0
	WHEN EXTRACT(EPOCH FROM (cardiac_dev.dod - icustays.intime)/(60*60)) IS NULL THEN 0
	ELSE 1 END AS d_in_icu
	
FROM cardiac_dev
	INNER JOIN icustays
	ON icustays.hadm_id = cardiac_dev.hadm_id
),
-- collect the top 3 listed diagnoses
diagnoses(hadm_id, diagnoses) AS (
	WITH order_icd AS(
	SELECT hadm_id, diagnoses_icd.icd9_code,
		--order the diagnoses to get the top 3 diagnoses listed
		RANK() OVER (PARTITION BY diagnoses_icd.hadm_id ORDER BY diagnoses_icd.seq_num ASC)
		FROM diagnoses_icd
	)
	SELECT order_icd.hadm_id, CONCAT(order_icd.icd9_code, ': ', d_icd_diagnoses.long_title) as diagnoses
	FROM order_icd
		INNER JOIN d_icd_diagnoses
		ON order_icd.icd9_code = d_icd_diagnoses.icd9_code		
	WHERE RANK < 4
)

SELECT icustaytime.subject_id, 
	icustaytime.gender, 
	icustaytime.age,
	icustaytime.los, 
	icustaytime.firsticu, 
	ARRAY_AGG(diagnoses.diagnoses)
	
FROM icustaytime
INNER JOIN diagnoses
ON icustaytime.hadm_id = diagnoses.hadm_id
WHERE icustaytime.d_in_icu = 1 
GROUP BY icustaytime.subject_id, icustaytime.gender, icustaytime.age, icustaytime.los,
	icustaytime.icu_id, icustaytime.firsticu 
;
--saved as "death_icu.csv"
	
/* Quesetion 5 */

--table for average stay for each care unit

WITH total_icustay(hadm_id, careunit, tot_stay) AS(
SELECT DISTINCT transfers.hadm_id,  
	transfers.curr_careunit,  
	SUM(transfers.los)/24 as tot_stay --total stay per h-ad, per ICU
	
FROM transfers
WHERE transfers.curr_careunit IS NOT NULL
GROUP BY transfers.curr_careunit, transfers.hadm_id
ORDER BY transfers.hadm_id
)


--calculating the aggregated average for this group
SELECT AVG(tot_stay) AS agg_avg
FROM total_icustay --4.59


SELECT DISTINCT total_icustay.careunit, AVG(total_icustay.tot_stay) AS avg_staytime
FROM total_icustay
GROUP BY total_icustay.careunit
;
--saved as "icu_average.csv"
 
--60-65s with cardiac device
WITH age_cardiac(subject_id, hadm_id) AS(
SELECT patients.subject_id, 
	admissions.hadm_id
FROM patients
INNER JOIN admissions
	ON patients.subject_id = admissions.subject_id
	INNER JOIN  diagnoses_icd
		ON admissions.hadm_id = diagnoses_icd.hadm_id
WHERE diagnoses_icd.icd9_code LIKE '%V450%' AND
	(FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) >= 60 and 
	FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) <= 65)
), 

total_icustay(hadm_id, careunit, tot_stay) AS(
SELECT DISTINCT transfers.hadm_id, 
	transfers.curr_careunit,  
	SUM(transfers.los)/24 AS tot_stay
	--mean in hours
FROM transfers
WHERE transfers.curr_careunit IS NOT NULL
GROUP BY transfers.curr_careunit, transfers.hadm_id
ORDER BY transfers.hadm_id
)

/*
--calculating the aggregated average for this group
SELECT AVG(tot_stay) AS agg_avg
FROM total_icustay
INNER JOIN age_cardiac
ON age_cardiac.hadm_id = total_icustay.hadm_id--3.59
*/

SELECT DISTINCT total_icustay.careunit, 
	AVG(total_icustay.tot_stay) AS avg_staytime
FROM total_icustay
INNER JOIN age_cardiac
ON total_icustay.hadm_id = age_cardiac.hadm_id
GROUP BY total_icustay.careunit
;

--saved as "60-65_average.csv"

--patients aged 60-65 with a simvastatin prescription
WITH age_cardiac(subject_id, hadm_id) AS(
SELECT patients.subject_id, 
	admissions.hadm_id
FROM patients
INNER JOIN admissions
	ON patients.subject_id = admissions.subject_id
	INNER JOIN  diagnoses_icd
		ON admissions.hadm_id = diagnoses_icd.hadm_id
WHERE diagnoses_icd.icd9_code LIKE '%V450%' AND
	(FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) >= 60 and 
	FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) <= 65)
), 

total_icustay(hadm_id, careunit, tot_stay) AS(
--sum up the los for each icu per hospital admission
SELECT DISTINCT transfers.hadm_id, 
	transfers.curr_careunit,  
	SUM(transfers.los)/24 AS tot_stay
FROM transfers
INNER JOIN age_cardiac
ON age_cardiac.hadm_id = transfers.hadm_id
WHERE transfers.curr_careunit IS NOT NULL AND
	EXISTS (
	SELECT prescriptions.hadm_id,
		prescriptions.drug
	FROM prescriptions
	WHERE drug LIKE '%imvastatin' AND
		prescriptions.subject_id = transfers.subject_id
	)
GROUP BY transfers.curr_careunit, transfers.hadm_id
ORDER BY transfers.hadm_id
) 

/*
--calculating the aggregated average for this group
SELECT AVG(tot_stay) AS agg_avg
FROM total_icustay --3.99
*/


--take the average length of stay per care unit
SELECT DISTINCT total_icustay.careunit, AVG(total_icustay.tot_stay) AS avg_staytime
FROM total_icustay
GROUP BY total_icustay.careunit
;
--saved as simvastatin.csv

--60-65 w cardiac NOT simvastatin

WITH age_cardiac(subject_id, hadm_id) AS(
SELECT patients.subject_id, 
	admissions.hadm_id
FROM patients
INNER JOIN admissions
	ON patients.subject_id = admissions.subject_id
	INNER JOIN  diagnoses_icd
		ON admissions.hadm_id = diagnoses_icd.hadm_id
WHERE diagnoses_icd.icd9_code LIKE '%V450%' AND
	(FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) >= 60 and 
	FLOOR(EXTRACT (EPOCH FROM admissions.admittime - patients.dob)/(24*60*60*365.25)) <= 65)
), 

total_icustay(hadm_id, careunit, tot_stay) AS(
--sum up the los for each icu per hospital admission
SELECT DISTINCT transfers.hadm_id, 
	transfers.curr_careunit,  
	SUM(transfers.los)/24 AS tot_stay
FROM transfers
INNER JOIN age_cardiac
	ON age_cardiac.hadm_id = transfers.hadm_id
	--no simvastatin pescribed to patient
WHERE transfers.curr_careunit IS NOT NULL AND
	NOT EXISTS (
	SELECT prescriptions.hadm_id,
		prescriptions.drug
	FROM prescriptions
	WHERE drug LIKE '%imvastatin' AND
		prescriptions.subject_id = transfers.subject_id
	)
GROUP BY transfers.curr_careunit, transfers.hadm_id
ORDER BY transfers.hadm_id
)
/*
--calculating the aggregated average for this group
SELECT AVG(tot_stay) AS agg_avg
FROM total_icustay --3.50

*/
--take the average length of stay per care unit
SELECT DISTINCT total_icustay.careunit, AVG(total_icustay.tot_stay) AS avg_staytime
FROM total_icustay
GROUP BY total_icustay.careunit
;
--saved as not_simvastatin.csv
